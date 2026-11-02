// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {AccumulationHook} from "../src/AccumulationHook.sol";
import {AccumulationHookTestBase} from "./utils/AccumulationHookTestBase.sol";

/**
 * @notice Commission S08-M1-015, section 5 item 4: no way to change the fee or the accepted pools after deployment.
 * The hook's only state-changing functions are the 10 inherited `IHooks` entry points; each refuses every caller but
 * the pool manager, and the 8 the hook does not use refuse the pool manager too. It has no storage, makes no calls,
 * and nothing outside it can change the fee a swap pays. `forge inspect` output for the ABI and storage layout is in
 * the STOP report.
 */
contract AccumulationHookNoChangePathTest is AccumulationHookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev keccak256 of the hook's initcode as reviewed in W3 (report 013: sha256 of the artifact hex string
    /// 2342e081...). A test failure here means the tests are not running against the reviewed bytecode.
    bytes32 internal constant REVIEWED_INITCODE_KECCAK =
        0x51e72c6f84175f3fc2239f0b51e4dbca2cc477114d20f6fa39f2a042c3c39abb;

    function test_testsRunAgainstReviewedBytecode() public pure {
        assertEq(keccak256(type(AccumulationHook).creationCode), REVIEWED_INITCODE_KECCAK);
    }

    function test_permissionsAndConstants() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(hook.USDC(), USDC);
        assertEq(hook.STRK(), STRK);
        assertEq(hook.USDC_TO_STRK_FEE(), 30_000);
        assertEq(hook.STRK_TO_USDC_FEE(), 10_000);
        assertEq(address(hook.poolManager()), address(manager));
    }

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

    /// @dev Nothing else is callable: any selector outside the 16 in the ABI reverts (no fallback, no receive), and
    /// so does sending ETH.
    function testFuzz_noOtherFunction(bytes4 selector, bytes calldata args) public {
        bytes4[16] memory known = [
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
            hook.USDC.selector,
            hook.STRK.selector,
            hook.USDC_TO_STRK_FEE.selector,
            hook.STRK_TO_USDC_FEE.selector
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
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The fee cannot be changed from outside
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The pool manager lets only the pool's own hook set a dynamic pool's stored fee. Its owner, the LP, the
    /// trader and anyone else are refused.
    function test_nobodyCanSetStoredFee() public {
        _initAndSeed(hookedKey);
        address[5] memory callers = [v4Owner, address(this), lp, trader, makeAddr("anyone")];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector);
            manager.updateDynamicLPFee(hookedKey, 50_000);
        }
        (,,, uint24 lpFee) = manager.getSlot0(hookedKey.toId());
        assertEq(lpFee, 0);
    }

    /// @dev Even the stored fee is irrelevant. The hook has no code that calls the pool manager (see the lifecycle
    /// test below), but if the hook's address could set the stored fee, swaps would still pay 3% and 1%: the hook's
    /// per-swap override replaces the stored fee on every swap.
    function test_storedFeeIsNeverUsed() public {
        _initAndSeed(hookedKey);
        vm.prank(address(hook));
        manager.updateDynamicLPFee(hookedKey, 500_000);
        (,,, uint24 lpFee) = manager.getSlot0(hookedKey.toId());
        assertEq(lpFee, 500_000);
        assertEq(_swap(hookedKey, true, -1_000e6, MIN_PRICE_LIMIT, "").eventFee, FEE_USDC_TO_STRK);
        assertEq(_swap(hookedKey, false, -8_000e18, MAX_PRICE_LIMIT, "").eventFee, FEE_STRK_TO_USDC);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // No storage, no outgoing calls, no tokens, over a full pool lifecycle
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Records every account and storage access while a pool is created, liquidity is added, swaps run in all
    /// four modes, liquidity is increased, reduced, collected and fully removed. The hook:
    /// - is called only by the pool manager, with no value, only `afterInitialize` (once) and `beforeSwap` (once per
    ///   swap), and never during liquidity changes;
    /// - reads and writes no storage slot of its own;
    /// - calls, creates or transfers nothing;
    /// - holds no tokens, claims or ETH afterwards.
    function test_fullLifecycle_hookHasNoStorageMakesNoCallsHoldsNothing() public {
        vm.startStateDiffRecording();
        uint256 tokenId = _initAndSeed(hookedKey);
        _swap(hookedKey, true, -50_000e6, MIN_PRICE_LIMIT, "");
        _swap(hookedKey, true, 100_000e18, MIN_PRICE_LIMIT, "");
        _swap(hookedKey, false, -400_000e18, MAX_PRICE_LIMIT, hex"c0ffee");
        _swap(hookedKey, false, 10_000e6, MAX_PRICE_LIMIT, "");
        _increase(lp, tokenId, positionLiquidity / 2);
        _decrease(lp, tokenId, positionLiquidity / 3);
        _collect(lp, tokenId);
        _burn(lp, tokenId);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();

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
        _assertHookHoldsNothing();
        assertEq(manager.getLiquidity(hookedKey.toId()), 0, "all liquidity removed");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _entryPointCalls() internal view returns (bytes[10] memory calls) {
        PoolKey memory key = hookedKey;
        ModifyLiquidityParams memory mlp =
            ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1e18, salt: 0});
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        BalanceDelta zero = BalanceDelta.wrap(0);
        calls[0] = abi.encodeCall(IHooks.beforeInitialize, (address(this), key, sqrtPriceInit));
        calls[1] = abi.encodeCall(IHooks.afterInitialize, (address(this), key, sqrtPriceInit, INIT_TICK));
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
