// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {NoDelegateCall} from "@uniswap/v4-core/src/NoDelegateCall.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {
    AsymmetricFee30bpTestBase,
    UsesHook_30bp_100bp,
    UsesHook_100bp_30bp
} from "./utils/AsymmetricFee30bpTestBase.sol";

/**
 * @notice The test setup itself: a working v4-core `PoolManager` at Ethereum mainnet's PoolManager address (the only
 * caller the hooks answer), and each hook deployed there with the right permission bits and getters.
 */
abstract contract AsymmetricFee30bpSetupTests is AsymmetricFee30bpTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev The PoolManager at the mainnet address: its constructor ran there, so the owner reads back, its
    /// no-delegate-call check accepts that address, and it holds nothing yet.
    function test_poolManagerPlacedAtMainnetAddress() public {
        assertEq(address(manager), MAINNET_POOL_MANAGER);
        assertGt(MAINNET_POOL_MANAGER.code.length, 0);
        assertEq(PoolManager(MAINNET_POOL_MANAGER).owner(), v4Owner, "owner read back from storage");
        assertEq(PoolManager(MAINNET_POOL_MANAGER).protocolFeeController(), address(0));
        assertEq(MAINNET_POOL_MANAGER.balance, 0);
        emit log_named_uint("PoolManager runtime size at the mainnet address", MAINNET_POOL_MANAGER.code.length);
    }

    /// @dev A pool initializes (through `noDelegateCall`), takes liquidity, and a swap settles both ways, on a control
    /// pool (no hook) and on the hooked pool.
    function test_placedPoolManagerInitializesAndSettles() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _initAndSeedPair(p);
            (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(_hookedKey(p).toId());
            assertEq(sqrtPriceX96, _sqrtInit(p));
            assertEq(tick, pairs[p].initTick);
            assertEq(manager.getLiquidity(_hookedKey(p).toId()), pairs[p].liquidity);
            SwapResult memory r = _swap(_staticKey(p, FEE_0_3PCT), true, -1e18, MIN_PRICE_LIMIT, "");
            assertEq(r.delta0, -1e18);
            assertGt(r.delta1, 0);
            r = _swap(_hookedKey(p), false, -1e18, MAX_PRICE_LIMIT, "");
            assertEq(r.delta1, -1e18);
            assertGt(r.delta0, 0);
        }
    }

    /// @dev Why the creation code must run at the address: a plain copy of a PoolManager's runtime code keeps the
    /// address it was built at in its no-delegate-call check, so every pool operation at the copy reverts.
    function test_plainCopyOfPoolManagerCodeWouldNotWork() public {
        PoolManager elsewhere = new PoolManager(v4Owner);
        address copy = makeAddr("copy");
        vm.etch(copy, address(elsewhere).code);
        vm.expectRevert(NoDelegateCall.DelegateCallNotAllowed.selector);
        IPoolManager(copy).initialize(_staticKey(LOW_MID, FEE_0_3PCT), _sqrtInit(LOW_MID));
        assertEq(PoolManager(copy).owner(), address(0), "storage (the owner) does not come with a code copy");
    }

    /// @dev The hook sits at an address with exactly the after-initialize and before-swap bits, answers the mainnet
    /// PoolManager, and reports the fees the README table gives for it.
    function test_hookAddressPermissionsAndGetters() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x1080);
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
        assertEq(address(hook.POOL_MANAGER()), MAINNET_POOL_MANAGER);
        assertEq(address(hook.poolManager()), MAINNET_POOL_MANAGER);
        assertEq(hook.TOKEN0_IN_FEE(), _token0InFee());
        assertEq(hook.TOKEN1_IN_FEE(), _token1InFee());
    }

    /// @dev Gas price zero for the whole run, so ETH balance changes are only what the contracts moved.
    function test_gasPriceIsZero() public view {
        assertEq(tx.gasprice, 0);
    }

    /// @dev The tokens sort as the tests assume: ETH < LOW < MID < HIGH.
    function test_tokenOrder() public view {
        assertLt(uint160(address(0)), uint160(TOKEN_LOW));
        assertLt(uint160(TOKEN_LOW), uint160(TOKEN_MID));
        assertLt(uint160(TOKEN_MID), uint160(TOKEN_HIGH));
        assertTrue(_hookedKey(ETH_MID).currency0.isAddressZero());
    }
}

contract AsymmetricFee_30bp_100bp_SetupTest is AsymmetricFee30bpSetupTests, UsesHook_30bp_100bp {}

contract AsymmetricFee_100bp_30bp_SetupTest is AsymmetricFee30bpSetupTests, UsesHook_100bp_30bp {}
