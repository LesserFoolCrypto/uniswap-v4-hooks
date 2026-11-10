// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {AsymmetricFeeBase} from "../src/AsymmetricFeeBase.sol";
import {
    AsymmetricFee30bpTestBase,
    UsesHook_30bp_100bp,
    UsesHook_100bp_30bp
} from "./utils/AsymmetricFee30bpTestBase.sol";

/**
 * @notice Expected failures: deploying at an address without exactly the `0x1080` bits; calls into the hook not from
 * the PoolManager; malformed calls into the hook, the PoolManager and the PositionManager (each reverts and changes
 * nothing); and boundary swaps: zero amount, the smallest swaps that move tokens, price-limited swaps, and swaps that
 * cross most of a position's range. (A pool without the dynamic fee flag is in `AsymmetricFee30bpPools.t.sol`.)
 */
abstract contract AsymmetricFee30bpFailuresTests is AsymmetricFee30bpTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------------------------
    // Wrong permission bits
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Deploying where the low 14 address bits are anything but exactly 0x1080 reverts `HookAddressNotValid`:
    /// no bits, one of the two, a wrong neighbour, the right two plus one more, all 14.
    function test_deployRevertsUnlessExactly0x1080() public {
        uint160[10] memory wrongBits = [
            uint160(0x0000),
            0x0080, // before-swap only
            0x1000, // after-initialize only
            0x2080, // before-initialize instead of after-initialize
            0x1040, // after-swap instead of before-swap
            0x3080, // + before-initialize
            0x1880, // + before-add-liquidity
            0x1280, // + before-remove-liquidity
            0x1088, // + before-swap-returns-delta
            0x3FFF // everything
        ];
        for (uint256 i; i < wrongBits.length; ++i) {
            (bytes32 salt, address predicted) = _mineSalt(_hookCreationCode(), wrongBits[i], 0);
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
            _newHook(salt);
        }
    }

    /// @dev Any salt: the deployment succeeds exactly when the address carries 0x1080 in its low 14 bits.
    function testFuzz_deploySucceedsOnlyWithExactBits(uint256 salt) public {
        address predicted = _create2Address(bytes32(salt), keccak256(_hookCreationCode()));
        vm.assume(predicted.code.length == 0);
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
            assertEq(address(_newHook(bytes32(salt))), predicted);
        } else {
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
            _newHook(bytes32(salt));
        }
    }

    /// @dev Other addresses with exactly 0x1080 work too; only the low 14 bits matter.
    function test_deploySucceedsAtOtherAddressesWithExactBits() public {
        for (uint256 i; i < 3; ++i) {
            (bytes32 salt, address predicted) = _mineSalt(_hookCreationCode(), HOOK_FLAGS, 1_000_000 * (i + 1));
            AsymmetricFeeBase other = _newHook(salt);
            assertEq(address(other), predicted);
            assertEq(other.TOKEN0_IN_FEE(), _token0InFee());
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Calls not from the PoolManager
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The two entry points the hook uses, called with well-formed arguments by every other party in these
    /// tests, revert `NotPoolManager`. (All 10 entry points against any caller: `AsymmetricFee30bpNoChangePath.t.sol`.)
    function test_usedEntryPointsRefuseOtherCallers() public {
        _initAndSeed(ETH_MID, _hookedKey(ETH_MID));
        address[7] memory callers =
            [lp, trader, v4Owner, address(posm), address(swapRouter), address(this), address(hook)];
        bytes[2] memory calls = [
            abi.encodeCall(IHooks.afterInitialize, (trader, _hookedKey(LOW_MID), _sqrtInit(LOW_MID), int24(0))),
            abi.encodeCall(
                IHooks.beforeSwap,
                (
                    trader,
                    _hookedKey(ETH_MID),
                    SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                    bytes("")
                )
            )
        ];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool ok, bytes memory ret) = address(hook).call(calls[j]);
                assertFalse(ok);
                assertEq(ret, abi.encodeWithSelector(NOT_POOL_MANAGER));
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Malformed encoding: reverts and changes nothing
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Calls into the hook, as the pool manager, with truncated arguments (two ways), an invalid bool in the
    /// swap direction, an unknown selector, a bare selector and empty calldata. (Calldata words the hook never reads,
    /// such as the key's tick spacing, are not validated by solc, so a dirty value there is not a malformed call.)
    function test_malformedCallsIntoHookRevertAndChangeNothing() public {
        _initAndSeed(ETH_MID, _hookedKey(ETH_MID));
        bytes memory good = abi.encodeCall(
            IHooks.beforeSwap,
            (
                trader,
                _hookedKey(ETH_MID),
                SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
                bytes("")
            )
        );
        // Words after the selector: sender, key (5 words), params (zeroForOne, amountSpecified, limit), hookData.
        bytes[] memory bad = new bytes[](6);
        bad[0] = _truncate(good, 4 + 32 * 3);
        bad[1] = _truncate(good, good.length - 1);
        bad[2] = _setWord(good, 6, bytes32(uint256(2))); // zeroForOne = 2: not a bool
        bad[3] = abi.encodePacked(bytes4(0xdeadbeef), good);
        bad[4] = abi.encodePacked(IHooks.afterInitialize.selector);
        bad[5] = "";
        for (uint256 i; i < bad.length; ++i) {
            _assertRevertsAndChangesNothing(address(manager), address(hook), bad[i]);
        }
        (bool ok,) = _callAs(address(manager), address(hook), good);
        assertTrue(ok, "the well-formed call still works");
    }

    /// @dev Calls into the pool manager with truncated or invalid arguments and an unknown selector.
    function test_malformedCallsIntoPoolManagerRevertAndChangeNothing() public {
        _initAndSeed(ETH_MID, _hookedKey(ETH_MID));
        PoolKey memory fresh = _hookedKey(ETH_MID);
        fresh.tickSpacing = 10;
        bytes memory init = abi.encodeCall(IPoolManager.initialize, (fresh, _sqrtInit(ETH_MID)));
        // Words after the selector: key (currency0, currency1, fee, tickSpacing, hooks), sqrtPriceX96.
        bytes[] memory bad = new bytes[](6);
        bad[0] = _truncate(init, init.length - 1);
        bad[1] = _truncate(init, 4 + 32 * 2);
        bad[2] = _setWord(init, 2, bytes32(uint256(1) << 23 | uint256(1) << 24)); // fee with bits past uint24
        bad[3] = _setWord(init, 5, bytes32(uint256(1) << 160)); // sqrtPrice with bits past uint160
        bad[4] = abi.encodePacked(bytes4(0xdeadbeef), init);
        bad[5] = _truncate(
            abi.encodeCall(
                IPoolManager.swap,
                (
                    _hookedKey(ETH_MID),
                    SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 1}),
                    bytes("")
                )
            ),
            100
        );
        for (uint256 i; i < bad.length; ++i) {
            _assertRevertsAndChangesNothing(trader, address(manager), bad[i]);
        }
        (bool ok,) = _callAs(trader, address(manager), init);
        assertTrue(ok, "the well-formed initialize still works");
    }

    /// @dev Malformed action data into the position manager, with and without ETH, reverts and leaves the LP's
    /// balances and position alone.
    function test_malformedActionsIntoPositionManagerRevert() public {
        uint256 id = _initAndSeed(ETH_MID, _hookedKey(ETH_MID));
        uint128 liquidityBefore = posm.getPositionLiquidity(id);
        bytes[] memory bad = new bytes[](3);
        bad[0] = abi.encodeCall(posm.modifyLiquidities, (hex"deadbeef", block.timestamp));
        bad[1] = abi.encodeCall(posm.modifyLiquidities, (abi.encode(hex"01", new bytes[](0)), block.timestamp));
        bad[2] = abi.encodeCall(posm.modifyLiquidities, (abi.encode(hex"ff", new bytes[](1)), block.timestamp));
        for (uint256 i; i < bad.length; ++i) {
            _assertRevertsAndChangesNothing(lp, address(posm), bad[i]);
            uint256 ethBefore = lp.balance;
            vm.prank(lp);
            (bool ok,) = address(posm).call{value: 1 ether}(bad[i]);
            assertFalse(ok);
            assertEq(lp.balance, ethBefore, "ETH sent with a failed call comes back");
            assertEq(address(posm).balance, 0);
        }
        assertEq(posm.getPositionLiquidity(id), liquidityBefore);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Boundary swaps
    // ---------------------------------------------------------------------------------------------------------------

    function test_zeroAmountSwapReverts() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _initAndSeed(p, _hookedKey(p));
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                vm.prank(trader);
                vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
                swapRouter.swap(
                    _hookedKey(p),
                    SwapParams({zeroForOne: zeroForOne, amountSpecified: 0, sqrtPriceLimitX96: _limit(zeroForOne)}),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    ""
                );
            }
        }
    }

    /// @dev The smallest swaps behave exactly as on the control pools, on every pair and both ways: an exact input of
    /// one base unit (all fee, nothing out); an exact output of one base unit, which gives the smallest input `n`
    /// that moves tokens; exact inputs of `n` (moves at least one unit) and `n - 1`.
    function test_smallestSwapsMatchControlPools() public {
        _initAndSeedAllPairs();
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                SwapResult memory r = _matchControl(p, zeroForOne, -1, "");
                assertEq(zeroForOne ? r.delta0 : r.delta1, -1, "1 base unit in");
                assertEq(zeroForOne ? r.delta1 : r.delta0, 0, "buys nothing: the fee rounds the net input to 0");

                r = _matchControl(p, zeroForOne, 1, "");
                assertEq(zeroForOne ? r.delta1 : r.delta0, 1, "exactly 1 base unit out");
                uint256 n = uint256(-(zeroForOne ? r.delta0 : r.delta1));
                emit log_named_uint("pair / direction (pair * 2 + (zeroForOne ? 0 : 1))", p * 2 + d);
                emit log_named_uint("  base units in for exactly 1 base unit out", n);
                r = _matchControl(p, zeroForOne, -int256(n), "");
                assertGe(zeroForOne ? r.delta1 : r.delta0, 1, "that input moves tokens");
                r = _matchControl(p, zeroForOne, -int256(n - 1), "");
                emit log_named_int("  base units out for one base unit less in", zeroForOne ? r.delta1 : r.delta0);
            }
        }
    }

    /// @dev A swap that hits its price limit stops exactly there, takes only part of the exact input, and still
    /// matches the control pool. Limits on the wrong side or out of bounds revert in the pool manager.
    function test_priceLimit() public {
        _initAndSeedAllPairs();
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _checkPriceLimit(p);
        }
    }

    function _checkPriceLimit(uint256 p) internal {
        uint160 below = TickMath.getSqrtPriceAtTick(pairs[p].initTick - 120);
        uint160 above = TickMath.getSqrtPriceAtTick(pairs[p].initTick + 120);
        uint256 snap = vm.snapshotState();
        SwapResult memory h = _swap(_hookedKey(p), true, -1_000_000e18, below, "");
        vm.revertToState(snap);
        _assertSameSwap(h, _swap(_controlKey(p, true), true, -1_000_000e18, below, ""));
        vm.revertToState(snap);
        assertEq(h.sqrtPriceX96, below, "stopped at the limit");
        assertGt(h.delta0, -1_000_000e18, "partial fill");
        assertEq(h.eventFee, _feeFor(true));

        h = _swap(_hookedKey(p), false, -1_000_000e18, above, "");
        vm.revertToState(snap);
        _assertSameSwap(h, _swap(_controlKey(p, false), false, -1_000_000e18, above, ""));
        vm.revertToState(snap);
        assertEq(h.sqrtPriceX96, above);
        assertGt(h.delta1, -1_000_000e18);
        assertEq(h.eventFee, _feeFor(false));

        uint160 start = _sqrtInit(p);
        _expectSwapRevert(p, true, above, abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, start, above));
        _expectSwapRevert(
            p, false, below, abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, start, below)
        );
        _expectSwapRevert(
            p,
            true,
            TickMath.MIN_SQRT_PRICE,
            abi.encodeWithSelector(Pool.PriceLimitOutOfBounds.selector, TickMath.MIN_SQRT_PRICE)
        );
        _expectSwapRevert(
            p,
            false,
            TickMath.MAX_SQRT_PRICE,
            abi.encodeWithSelector(Pool.PriceLimitOutOfBounds.selector, TickMath.MAX_SQRT_PRICE)
        );
    }

    /// @dev Swaps that cross most of the position's range, down to one tick spacing above the bottom and then up to
    /// one tick spacing below the top (about 99% of the range), match the control pools; the LP then withdraws
    /// everything. On the native-ETH pair and a two-token pair.
    function test_swapsAcrossMostOfTheRange() public {
        uint256[2] memory pairIds = [ETH_MID, MID_HIGH];
        for (uint256 j; j < pairIds.length; ++j) {
            uint256 p = pairIds[j];
            uint256 id = _initAndSeedPair(p);
            uint160 nearBottom = TickMath.getSqrtPriceAtTick(pairs[p].tickLower + TICK_SPACING);
            uint160 nearTop = TickMath.getSqrtPriceAtTick(pairs[p].tickUpper - TICK_SPACING);

            // Down: token0 in until one tick spacing above the bottom of the range (about half the range). More than
            // enough token0 is offered (for ETH, 5,000 ETH sent as value); the limit stops the swap.
            int256 down = p == ETH_MID ? -5_000e18 : -10_000_000e18;
            SwapResult memory h = _swap(_hookedKey(p), true, down, nearBottom, "");
            _assertSameSwap(h, _swap(_controlKey(p, true), true, down, nearBottom, ""));
            assertEq(h.sqrtPriceX96, nearBottom);
            assertGt(h.delta0, down, "partial fill at the limit");
            assertEq(h.eventFee, _feeFor(true));

            // Bring the other control pool to the same price; the fee on the way down does not change the price.
            _alignControlsWithHooked(p);
            // Up: token1 in from near the bottom to one tick spacing below the top (about 99% of the range).
            h = _swap(_hookedKey(p), false, -100_000_000e18, nearTop, "");
            _assertSameSwap(h, _swap(_controlKey(p, false), false, -100_000_000e18, nearTop, ""));
            assertEq(h.sqrtPriceX96, nearTop);
            assertEq(h.eventFee, _feeFor(false));

            (uint256 got0, uint256 got1) = _burn(lp, id);
            assertGt(got0 + got1, 0);
            assertEq(manager.getLiquidity(_hookedKey(p).toId()), 0);
            _assertHookHoldsNothing();
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _expectSwapRevert(uint256 p, bool zeroForOne, uint160 limit, bytes memory reason) internal {
        PoolKey memory key = _hookedKey(p);
        uint256 value = _swapValue(key, zeroForOne, -1e18);
        vm.prank(trader);
        vm.expectRevert(reason);
        swapRouter.swap{value: value}(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _callAs(address from, address to, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = to.call(data);
    }

    /// @dev The call fails, and every storage write made during it was rolled back (and no ETH moved).
    function _assertRevertsAndChangesNothing(address from, address to, bytes memory data) internal {
        vm.startStateDiffRecording();
        (bool ok,) = _callAs(from, to, data);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertFalse(ok, "malformed call reverted");
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account == to && accesses[i].kind == VmSafe.AccountAccessKind.Call) {
                assertTrue(accesses[i].reverted, "call marked reverted");
            }
            for (uint256 j; j < accesses[i].storageAccesses.length; ++j) {
                Vm.StorageAccess memory s = accesses[i].storageAccesses[j];
                if (s.isWrite) assertTrue(s.reverted, "storage write rolled back");
            }
        }
    }

    function _truncate(bytes memory data, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[i];
        }
    }

    /// @dev Copy of `data` with ABI word `index` (counted after the 4-byte selector) replaced.
    function _setWord(bytes memory data, uint256 index, bytes32 word) internal pure returns (bytes memory out) {
        out = bytes.concat(data);
        uint256 offset = 4 + 32 * index;
        for (uint256 i; i < 32; ++i) {
            out[offset + i] = word[i];
        }
    }
}

contract AsymmetricFee_30bp_100bp_FailuresTest is AsymmetricFee30bpFailuresTests, UsesHook_30bp_100bp {}

contract AsymmetricFee_100bp_30bp_FailuresTest is AsymmetricFee30bpFailuresTests, UsesHook_100bp_30bp {}
