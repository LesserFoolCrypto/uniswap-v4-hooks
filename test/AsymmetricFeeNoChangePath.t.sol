// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {AsymmetricFeeTestBase, UsesHook_100bp_300bp, UsesHook_300bp_100bp} from "./utils/AsymmetricFeeTestBase.sol";

/**
 * @notice No way to change a hook after deployment, and it holds nothing. Its only state-changing functions are the
 * 10 inherited `IHooks` entry points; each refuses every caller but the pool manager, and the 8 the hook does not use
 * refuse the pool manager too. The other 5 functions are read-only getters. It has no `receive` or `fallback`, so
 * sending it ETH reverts. It reads and writes no storage, makes no calls, and nothing outside it can change the fee a
 * swap pays. (The empty storage layout from `forge inspect` is in the build record.)
 */
abstract contract AsymmetricFeeNoChangePathTests is AsymmetricFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev All 10 entry points revert `NotPoolManager` for any other caller.
    function testFuzz_entryPointsRefuseAnyCallerButManager(address caller) public {
        vm.assume(caller != address(manager));
        bytes[10] memory calls = _entryPointCalls();
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool ok, bytes memory ret) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(NOT_POOL_MANAGER));
        }
    }

    /// @dev The 8 unused entry points revert `HookNotImplemented` even for the pool manager. (The pool manager never
    /// calls them: their address bits are clear.)
    function test_unusedEntryPointsRefuseManagerToo() public {
        bytes[10] memory calls = _entryPointCalls();
        for (uint256 i; i < calls.length; ++i) {
            bytes4 selector = bytes4(calls[i]);
            if (selector == IHooks.afterInitialize.selector || selector == IHooks.beforeSwap.selector) continue;
            vm.prank(address(manager));
            (bool ok, bytes memory ret) = address(hook).call(calls[i]);
            assertFalse(ok);
            assertEq(ret, abi.encodeWithSelector(HOOK_NOT_IMPLEMENTED));
        }
    }

    /// @dev Nothing else is callable: any selector outside the 15 in the ABI reverts (no fallback, no receive), and
    /// so does sending ETH, with or without data.
    function testFuzz_noOtherFunction(bytes4 selector, bytes calldata args) public {
        bytes4[15] memory known = [
            IHooks.beforeInitialize.selector,
            IHooks.afterInitialize.selector,
            IHooks.beforeAddLiquidity.selector,
            IHooks.afterAddLiquidity.selector,
            IHooks.beforeRemoveLiquidity.selector,
            IHooks.afterRemoveLiquidity.selector,
            IHooks.beforeSwap.selector,
            IHooks.afterSwap.selector,
            IHooks.beforeDonate.selector,
            IHooks.afterDonate.selector,
            hook.getHookPermissions.selector,
            hook.poolManager.selector,
            hook.POOL_MANAGER.selector,
            hook.TOKEN0_IN_FEE.selector,
            hook.TOKEN1_IN_FEE.selector
        ];
        for (uint256 i; i < known.length; ++i) {
            vm.assume(selector != known[i]);
        }
        vm.prank(address(manager));
        (bool ok,) = address(hook).call(abi.encodePacked(selector, args));
        assertFalse(ok, "unknown selector");
        vm.deal(address(this), 1 ether);
        (ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "plain ETH transfer");
        (ok,) = address(hook).call{value: 1}(abi.encodePacked(selector, args));
        assertFalse(ok, "ETH with data");
        _assertHookHoldsNothing();
    }

    /// @dev Sending ETH directly reverts whoever sends it, the pool manager included, and through any of the 15
    /// functions (none is payable).
    function test_sendingEthDirectlyReverts() public {
        address[4] memory senders = [address(this), address(manager), lp, trader];
        for (uint256 i; i < senders.length; ++i) {
            vm.deal(senders[i], senders[i].balance + 1 ether);
            vm.prank(senders[i]);
            (bool ok,) = address(hook).call{value: 1 ether}("");
            assertFalse(ok, "plain transfer");
            vm.prank(senders[i]);
            (ok,) = address(hook).call{value: 1}(abi.encodeCall(hook.TOKEN0_IN_FEE, ()));
            assertFalse(ok, "value with a getter call");
        }
        vm.prank(address(manager));
        (bool sent,) = address(hook).call{value: 1}(_entryPointCalls()[6]);
        assertFalse(sent, "value with beforeSwap");
        _assertHookHoldsNothing();
    }

    /// @dev The five getters are read-only: a static call succeeds and returns the fixed values.
    function test_gettersAreReadOnly() public view {
        (bool ok, bytes memory ret) = address(hook).staticcall(abi.encodeCall(hook.TOKEN0_IN_FEE, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint24)), _token0InFee());
        (ok, ret) = address(hook).staticcall(abi.encodeCall(hook.TOKEN1_IN_FEE, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint24)), _token1InFee());
        (ok, ret) = address(hook).staticcall(abi.encodeCall(hook.POOL_MANAGER, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), MAINNET_POOL_MANAGER);
        (ok, ret) = address(hook).staticcall(abi.encodeCall(hook.poolManager, ()));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), MAINNET_POOL_MANAGER);
        (ok,) = address(hook).staticcall(abi.encodeCall(hook.getHookPermissions, ()));
        assertTrue(ok);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The fee cannot be changed from outside
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The pool manager lets only the pool's own hook set a dynamic pool's stored fee. Its owner, the LP, the
    /// trader and anyone else are refused.
    function test_nobodyCanSetStoredFee() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _initAndSeed(p, _hookedKey(p));
            address[5] memory callers = [v4Owner, address(this), lp, trader, makeAddr("anyone")];
            for (uint256 i; i < callers.length; ++i) {
                vm.prank(callers[i]);
                vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
                manager.updateDynamicLPFee(_hookedKey(p), 50_000);
            }
            (,,, uint24 lpFee) = manager.getSlot0(_hookedKey(p).toId());
            assertEq(lpFee, 0);
        }
    }

    /// @dev Even the stored fee is irrelevant. The hook has no code that calls the pool manager (see the lifecycle
    /// test below), but if the hook's address could set the stored fee, swaps would still pay the hook's fees: its
    /// per-swap override replaces the stored fee on every swap.
    function test_storedFeeIsNeverUsed() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _initAndSeed(p, _hookedKey(p));
            vm.prank(address(hook));
            manager.updateDynamicLPFee(_hookedKey(p), 500_000);
            (,,, uint24 lpFee) = manager.getSlot0(_hookedKey(p).toId());
            assertEq(lpFee, 500_000);
            assertEq(_swap(_hookedKey(p), true, -1e18, MIN_PRICE_LIMIT, "").eventFee, _token0InFee());
            assertEq(_swap(_hookedKey(p), false, -1e18, MAX_PRICE_LIMIT, "").eventFee, _token1InFee());
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // No storage, no outgoing calls, no tokens, over a full pool lifecycle
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Records every account and storage access while a pool is created, liquidity is added, swaps run in all
    /// four modes, liquidity is increased, reduced, collected and fully removed, on the native-ETH pair and on a
    /// two-token pair. The hook:
    /// - is called only by the pool manager, with no value, only `afterInitialize` (once) and `beforeSwap` (once per
    ///   swap), and never during liquidity changes;
    /// - reads and writes no storage slot of its own;
    /// - calls, creates or transfers nothing;
    /// - holds no ETH, tokens or claims afterwards.
    function test_fullLifecycle_hookHasNoStorageMakesNoCallsHoldsNothing() public {
        uint256[2] memory pairIds = [ETH_MID, MID_HIGH];
        for (uint256 j; j < pairIds.length; ++j) {
            uint256 p = pairIds[j];
            PoolKey memory key = _hookedKey(p);
            vm.startStateDiffRecording();
            uint256 tokenId = _initAndSeed(p, key);
            _swap(key, true, -50e18, MIN_PRICE_LIMIT, "");
            _swap(key, true, 1_000e18, MIN_PRICE_LIMIT, "");
            _swap(key, false, -40_000e18, MAX_PRICE_LIMIT, hex"c0ffee");
            _swap(key, false, 10e18, MAX_PRICE_LIMIT, "");
            _increase(lp, tokenId, pairs[p].liquidity / 2);
            _decrease(lp, tokenId, pairs[p].liquidity / 3);
            _collect(lp, tokenId);
            _burn(lp, tokenId);
            Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
            _checkHookAccesses(accesses);
            _assertHookHoldsNothing();
            assertEq(manager.getLiquidity(key.toId()), 0, "all liquidity removed");
        }
    }

    function _checkHookAccesses(Vm.AccountAccess[] memory accesses) internal view {
        uint256 initCalls;
        uint256 swapCalls;
        for (uint256 i; i < accesses.length; ++i) {
            Vm.AccountAccess memory a = accesses[i];
            for (uint256 j; j < a.storageAccesses.length; ++j) {
                assertTrue(a.storageAccesses[j].account != address(hook), "hook storage touched");
            }
            assertTrue(a.accessor != address(hook), "hook made a call or access");
            if (a.account != address(hook)) continue;
            if (a.kind != VmSafe.AccountAccessKind.Call) continue;
            assertEq(a.accessor, address(manager), "only the pool manager calls the hook");
            assertEq(a.value, 0);
            assertFalse(a.reverted);
            bytes4 selector = bytes4(a.data);
            if (selector == IHooks.afterInitialize.selector) ++initCalls;
            else if (selector == IHooks.beforeSwap.selector) ++swapCalls;
            else revert("unexpected hook call");
        }
        assertEq(initCalls, 1, "afterInitialize calls");
        assertEq(swapCalls, 4, "beforeSwap calls (one per swap, none for liquidity)");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _entryPointCalls() internal view returns (bytes[10] memory calls) {
        PoolKey memory key = _hookedKey(ETH_MID);
        ModifyLiquidityParams memory mlp = ModifyLiquidityParams({
            tickLower: pairs[ETH_MID].tickLower, tickUpper: pairs[ETH_MID].tickUpper, liquidityDelta: 1e18, salt: 0
        });
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        BalanceDelta zero = BalanceDelta.wrap(0);
        uint160 price = _sqrtInit(ETH_MID);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, price));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, price, ETH_MID_TICK));
        calls[2] = abi.encodeCall(IHooks.beforeAddLiquidity, (address(this), key, mlp, ""));
        calls[3] = abi.encodeCall(IHooks.afterAddLiquidity, (address(this), key, mlp, zero, zero, ""));
        calls[4] = abi.encodeCall(IHooks.beforeRemoveLiquidity, (address(this), key, mlp, ""));
        calls[5] = abi.encodeCall(IHooks.afterRemoveLiquidity, (address(this), key, mlp, zero, zero, ""));
        calls[6] = abi.encodeCall(IHooks.beforeSwap, (address(this), key, sp, ""));
        calls[7] = abi.encodeCall(IHooks.afterSwap, (address(this), key, sp, zero, ""));
        calls[8] = abi.encodeCall(IHooks.beforeDonate, (address(this), key, 1, 1, ""));
        calls[9] = abi.encodeCall(IHooks.afterDonate, (address(this), key, 1, 1, ""));
    }
}

contract AsymmetricFee_100bp_300bp_NoChangePathTest is AsymmetricFeeNoChangePathTests, UsesHook_100bp_300bp {}

contract AsymmetricFee_300bp_100bp_NoChangePathTest is AsymmetricFeeNoChangePathTests, UsesHook_300bp_100bp {}
