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

import {AccumulationHook} from "../src/AccumulationHook.sol";
import {AccumulationHookTestBase} from "./utils/AccumulationHookTestBase.sol";

/**
 * @notice Commission S08-M1-015, section 5 item 7: expected failures. Wrong permission bits, malformed encoding into
 * the hook, the pool manager and the position manager, and boundary swaps. (Invalid fee setup, a static-fee pool, is
 * in `AccumulationHookPools.t.sol`.)
 */
contract AccumulationHookFailuresTest is AccumulationHookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------------------------
    // Wrong permissions
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
            (bytes32 salt, address predicted) = _mineSalt(wrongBits[i], 0);
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
            new AccumulationHook{salt: salt}(manager);
        }
    }

    /// @dev Any salt: the deployment succeeds exactly when the address carries 0x1080 in its low 14 bits.
    function testFuzz_deploySucceedsOnlyWithExactBits(uint256 salt) public {
        address predicted = _create2Address(bytes32(salt), keccak256(_hookInitCode()));
        vm.assume(predicted.code.length == 0);
        if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
            assertEq(address(new AccumulationHook{salt: bytes32(salt)}(manager)), predicted);
        } else {
            vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
            new AccumulationHook{salt: bytes32(salt)}(manager);
        }
    }

    /// @dev Other addresses with exactly 0x1080 work too; only the low 14 bits matter.
    function test_deploySucceedsAtOtherAddressesWithExactBits() public {
        for (uint256 i; i < 3; ++i) {
            (bytes32 salt, address predicted) = _mineSalt(HOOK_FLAGS, 1_000_000 * (i + 1));
            AccumulationHook other = new AccumulationHook{salt: salt}(manager);
            assertEq(address(other), predicted);
            assertTrue(other.getHookPermissions().beforeSwap);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Malformed encoding: reverts and changes nothing
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Calls into the hook, as the pool manager, with truncated arguments (two ways), an invalid bool in the
    /// swap direction, an unknown selector, a bare selector and empty calldata. (Calldata words the hook never reads,
    /// such as the key's tick spacing, are not validated by solc, so a dirty value there is not a malformed call.)
    function test_malformedCallsIntoHookRevertAndChangeNothing() public {
        _initAndSeed(hookedKey);
        bytes memory good = abi.encodeCall(
            IHooks.beforeSwap,
            (
                trader,
                hookedKey,
                SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
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
        _initAndSeed(hookedKey);
        PoolKey memory fresh = hookedKey;
        fresh.tickSpacing = 10;
        bytes memory init = abi.encodeCall(IPoolManager.initialize, (fresh, sqrtPriceInit));
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
                (hookedKey, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 1}), bytes(""))
            ),
            100
        );
        for (uint256 i; i < bad.length; ++i) {
            _assertRevertsAndChangesNothing(trader, address(manager), bad[i]);
        }
        (bool ok,) = _callAs(trader, address(manager), init);
        assertTrue(ok, "the well-formed initialize still works");
    }

    /// @dev Malformed action data into the position manager reverts and leaves the LP's balances and position alone.
    function test_malformedActionsIntoPositionManagerRevert() public {
        uint256 id = _initAndSeed(hookedKey);
        uint128 liquidityBefore = posm.getPositionLiquidity(id);
        bytes[] memory bad = new bytes[](3);
        bad[0] = abi.encodeCall(posm.modifyLiquidities, (hex"deadbeef", block.timestamp));
        bad[1] = abi.encodeCall(posm.modifyLiquidities, (abi.encode(hex"01", new bytes[](0)), block.timestamp));
        bad[2] = abi.encodeCall(posm.modifyLiquidities, (abi.encode(hex"ff", new bytes[](1)), block.timestamp));
        for (uint256 i; i < bad.length; ++i) {
            _assertRevertsAndChangesNothing(lp, address(posm), bad[i]);
        }
        assertEq(posm.getPositionLiquidity(id), liquidityBefore);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Boundary cases
    // ---------------------------------------------------------------------------------------------------------------

    function test_zeroAmountSwapReverts() public {
        _initAndSeed(hookedKey);
        for (uint256 i; i < 2; ++i) {
            bool zeroForOne = i == 0;
            vm.prank(trader);
            vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
            swapRouter.swap(
                hookedKey,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: 0, sqrtPriceLimitX96: _limit(zeroForOne)}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
    }

    /// @dev The smallest swaps behave exactly as on the static pools. USDC in: 1 base unit is all fee and buys no
    /// STRK; the smallest input that moves STRK out is found and checked. STRK in: the input that buys exactly one
    /// USDC base unit, and one base unit less. Exact output of one base unit, both ways.
    function test_smallestSwapsMatchStaticPools() public {
        _initAndSeed(hookedKey);
        _initAndSeed(static3Key);
        _initAndSeed(static1Key);

        SwapResult memory r = _matchControl(true, -1);
        assertEq(r.usdcDelta, -1, "1 USDC base unit in");
        assertEq(r.strkDelta, 0, "buys nothing: 3% of 1 rounds the net input to 0");
        uint256 smallest;
        for (uint256 n = 1; n <= 10; ++n) {
            if (_matchControl(true, -int256(n)).strkDelta > 0) {
                smallest = n;
                break;
            }
        }
        assertEq(smallest, 2, "smallest USDC input that moves STRK");
        emit log_named_uint("STRK base units out for 2 USDC base units in", uint256(_matchControl(true, -2).strkDelta));

        r = _matchControl(false, 1); // exactly 1 USDC base unit out
        assertEq(r.usdcDelta, 1);
        uint256 strkForOneUnit = uint256(-r.strkDelta);
        emit log_named_uint("STRK base units in for exactly 1 USDC base unit out", strkForOneUnit);
        assertGt(_matchControl(false, -int256(strkForOneUnit)).usdcDelta, 0);
        _matchControl(false, -int256(strkForOneUnit - 1));
        r = _matchControl(false, -1);
        assertEq(r.strkDelta, -1);
        assertEq(r.usdcDelta, 0);

        r = _matchControl(true, 1); // exactly 1 STRK base unit out
        assertEq(r.strkDelta, 1);
        assertEq(r.usdcDelta, -2, "1 USDC base unit to the curve plus a 1-unit fee (rounded up)");
    }

    /// @dev A swap that hits its price limit stops exactly there, takes only part of the exact input, and still
    /// matches the static pool. Limits on the wrong side or out of bounds revert in the pool manager.
    function test_priceLimit() public {
        _initAndSeed(hookedKey);
        _initAndSeed(static3Key);
        _initAndSeed(static1Key);

        uint160 below = TickMath.getSqrtPriceAtTick(INIT_TICK - 120);
        uint256 snap = vm.snapshotState();
        SwapResult memory h = _swap(hookedKey, true, -1_000_000e6, below, "");
        vm.revertToState(snap);
        _assertSameSwap(h, _swap(static3Key, true, -1_000_000e6, below, ""));
        vm.revertToState(snap);
        assertEq(h.sqrtPriceX96, below, "stopped at the limit");
        assertGt(h.usdcDelta, -1_000_000e6, "partial fill");
        assertEq(h.eventFee, FEE_USDC_TO_STRK);
        emit log_named_uint("USDC base units used of 1,000,000 USDC, limit 120 ticks down", uint256(-h.usdcDelta));

        uint160 above = TickMath.getSqrtPriceAtTick(INIT_TICK + 120);
        h = _swap(hookedKey, false, -8_000_000e18, above, "");
        vm.revertToState(snap);
        _assertSameSwap(h, _swap(static1Key, false, -8_000_000e18, above, ""));
        vm.revertToState(snap);
        assertEq(h.sqrtPriceX96, above);
        assertGt(h.strkDelta, -8_000_000e18);
        assertEq(h.eventFee, FEE_STRK_TO_USDC);

        _expectSwapRevert(
            true, above, abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, sqrtPriceInit, above)
        );
        _expectSwapRevert(
            false, below, abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, sqrtPriceInit, below)
        );
        _expectSwapRevert(
            true,
            TickMath.MIN_SQRT_PRICE,
            abi.encodeWithSelector(Pool.PriceLimitOutOfBounds.selector, TickMath.MIN_SQRT_PRICE)
        );
        _expectSwapRevert(
            false,
            TickMath.MAX_SQRT_PRICE,
            abi.encodeWithSelector(Pool.PriceLimitOutOfBounds.selector, TickMath.MAX_SQRT_PRICE)
        );
    }

    /// @dev Swaps that cross most of the position's range, down to one tick spacing above the bottom and then up to
    /// one tick spacing below the top (about 99% of the range), match the static pools; the LP then withdraws
    /// everything.
    function test_swapsAcrossMostOfTheRange() public {
        uint256 id = _initAndSeed(hookedKey);
        _initAndSeed(static3Key);
        _initAndSeed(static1Key);
        uint160 nearBottom = TickMath.getSqrtPriceAtTick(TICK_LOWER + TICK_SPACING);
        uint160 nearTop = TickMath.getSqrtPriceAtTick(TICK_UPPER - TICK_SPACING);

        // Down: USDC in until one tick spacing above the bottom of the range (about half the range).
        SwapResult memory h = _swap(hookedKey, true, -10_000_000e6, nearBottom, "");
        _assertSameSwap(h, _swap(static3Key, true, -10_000_000e6, nearBottom, ""));
        assertEq(h.sqrtPriceX96, nearBottom);
        assertGt(h.usdcDelta, -10_000_000e6, "partial fill at the limit");
        assertEq(h.eventFee, FEE_USDC_TO_STRK);

        // Bring the static 1% pool to the same price; its fee on the way down does not change the price.
        _swap(static1Key, true, -10_000_000e6, nearBottom, "");
        // Up: STRK in from near the bottom to one tick spacing below the top (about 99% of the range).
        h = _swap(hookedKey, false, -100_000_000e18, nearTop, "");
        _assertSameSwap(h, _swap(static1Key, false, -100_000_000e18, nearTop, ""));
        assertEq(h.sqrtPriceX96, nearTop);
        assertEq(h.eventFee, FEE_STRK_TO_USDC);

        (uint256 gotUsdc, uint256 gotStrk) = _burn(lp, id);
        assertGt(gotUsdc + gotStrk, 0);
        assertEq(manager.getLiquidity(hookedKey.toId()), 0);
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _matchControl(bool zeroForOne, int256 amountSpecified) internal returns (SwapResult memory h) {
        uint256 snap = vm.snapshotState();
        h = _swap(hookedKey, zeroForOne, amountSpecified, _limit(zeroForOne), "");
        vm.revertToState(snap);
        _assertSameSwap(
            h, _swap(zeroForOne ? static3Key : static1Key, zeroForOne, amountSpecified, _limit(zeroForOne), "")
        );
        vm.revertToState(snap);
        assertEq(h.eventFee, zeroForOne ? FEE_USDC_TO_STRK : FEE_STRK_TO_USDC);
    }

    function _expectSwapRevert(bool zeroForOne, uint160 limit, bytes memory reason) internal {
        vm.prank(trader);
        vm.expectRevert(reason);
        swapRouter.swap(
            hookedKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: -1e6, sqrtPriceLimitX96: limit}),
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
