// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/fee/BaseOverrideFee.sol";

import {AsymmetricFeeTestBase, UsesHook_100bp_300bp, UsesHook_300bp_100bp} from "./utils/AsymmetricFeeTestBase.sol";

/**
 * @notice Which pools each hook accepts, tried on the core PoolManager directly. A pool without the dynamic fee flag
 * is refused; a dynamic-fee pool initializes with any two currencies (native ETH included, and addresses that are not
 * even tokens: initialization never touches them) at any tick spacing. Hook reverts arrive wrapped by the pool
 * manager: `WrappedError(hook, IHooks.afterInitialize.selector, NotDynamicFee(), HookCallFailed())`.
 */
abstract contract AsymmetricFeePoolsTests is AsymmetricFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 2 ** 96;

    // ---------------------------------------------------------------------------------------------------------------
    // Refused: no dynamic fee flag
    // ---------------------------------------------------------------------------------------------------------------

    function test_initialize_refusesStaticFeePools() public {
        uint24[8] memory fees = [uint24(0), 100, 500, 3_000, 10_000, 30_000, 100_000, LPFeeLibrary.MAX_LP_FEE];
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 i; i < fees.length; ++i) {
                PoolKey memory key = _key(p, fees[i], address(hook));
                vm.expectRevert(_notDynamicFee());
                manager.initialize(key, _sqrtInit(p));
                assertEq(_sqrtPrice(key), 0, "pool not created");
            }
        }
    }

    function testFuzz_initialize_refusesAnyStaticFee(uint24 fee, int24 spacing, uint256 pairSeed) public {
        fee = uint24(_bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));
        spacing = int24(_bound(int256(spacing), TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        uint256 p = pairSeed % PAIR_COUNT;
        PoolKey memory key = _key(p, fee, address(hook));
        key.tickSpacing = spacing;
        vm.expectRevert(_notDynamicFee());
        manager.initialize(key, _sqrtInit(p));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Accepted: dynamic fee flag, any currencies, any tick spacing
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Six pairs of the test currencies (three with native ETH), and one pair of addresses with no code, each at
    /// eight tick spacings from 1 to the maximum.
    function test_initialize_acceptsAnyCurrenciesAtManyTickSpacings() public {
        address[2][7] memory pairsToTry = [
            [address(0), TOKEN_LOW],
            [address(0), TOKEN_MID],
            [address(0), TOKEN_HIGH],
            [TOKEN_LOW, TOKEN_MID],
            [TOKEN_LOW, TOKEN_HIGH],
            [TOKEN_MID, TOKEN_HIGH],
            [address(0xC0DE), address(0xDEAD)]
        ];
        int24[8] memory spacings = [int24(1), 10, 60, 100, 200, 1_000, 16_384, TickMath.MAX_TICK_SPACING];
        for (uint256 i; i < pairsToTry.length; ++i) {
            for (uint256 s; s < spacings.length; ++s) {
                PoolKey memory key = _dynamicKey(pairsToTry[i][0], pairsToTry[i][1], spacings[s]);
                assertEq(manager.initialize(key, SQRT_PRICE_1_1), 0, "tick at 1:1");
                (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
                assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
                assertEq(protocolFee, 0);
                assertEq(lpFee, 0, "stored LP fee of a dynamic pool starts at 0 and is never used");
            }
        }
    }

    function testFuzz_initialize_acceptsAnyCurrenciesAndSpacing(address a, address b, int24 spacing, uint160 price)
        public
    {
        vm.assume(a != b);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        spacing = int24(_bound(int256(spacing), TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        price = uint160(_bound(price, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        PoolKey memory key = _dynamicKey(c0, c1, spacing);
        manager.initialize(key, price);
        assertEq(_sqrtPrice(key), price);
    }

    /// @dev The fee does not depend on the tick spacing: at spacings 1 and 200, on the native-ETH pair and a
    /// two-token pair, swaps both ways match the control pools at the same spacing.
    function test_feeSameAtTickSpacings1And200() public {
        int24[2] memory spacings = [int24(1), 200];
        uint256[2] memory pairIds = [ETH_MID, LOW_MID];
        for (uint256 s; s < spacings.length; ++s) {
            for (uint256 j; j < pairIds.length; ++j) {
                _checkFeeAtSpacing(pairIds[j], spacings[s]);
            }
        }
    }

    function _checkFeeAtSpacing(uint256 p, int24 spacing) internal {
        int24 lower = _floorTo(pairs[p].tickLower, spacing);
        int24 upper = _ceilTo(pairs[p].tickUpper, spacing);
        PoolKey memory hooked = _hookedKey(p);
        PoolKey memory c1 = _staticKey(p, FEE_1PCT);
        PoolKey memory c3 = _staticKey(p, FEE_3PCT);
        hooked.tickSpacing = spacing;
        c1.tickSpacing = spacing;
        c3.tickSpacing = spacing;
        PoolKey[3] memory keys = [hooked, c1, c3];
        for (uint256 k; k < keys.length; ++k) {
            manager.initialize(keys[k], _sqrtInit(p));
            _mint(lp, keys[k], lower, upper, pairs[p].liquidity);
        }
        for (uint256 d; d < 2; ++d) {
            bool zeroForOne = d == 0;
            PoolKey memory control = _feeFor(zeroForOne) == FEE_1PCT ? c1 : c3;
            uint256 snap = vm.snapshotState();
            SwapResult memory h = _swap(hooked, zeroForOne, -3e18, _limit(zeroForOne), "");
            vm.revertToState(snap);
            _assertSameSwap(h, _swap(control, zeroForOne, -3e18, _limit(zeroForOne), ""));
            vm.revertToState(snap);
            assertEq(h.eventFee, _feeFor(zeroForOne));
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _dynamicKey(address c0, address c1, int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: spacing,
            hooks: IHooks(address(hook))
        });
    }

    function _notDynamicFee() internal view returns (bytes memory) {
        return _wrappedHookError(
            IHooks.afterInitialize.selector, abi.encodeWithSelector(BaseOverrideFee.NotDynamicFee.selector)
        );
    }

    function _floorTo(int24 tick, int24 spacing) internal pure returns (int24 r) {
        r = tick / spacing * spacing;
        if (tick < 0 && r != tick) r -= spacing;
    }

    function _ceilTo(int24 tick, int24 spacing) internal pure returns (int24 r) {
        r = tick / spacing * spacing;
        if (tick > 0 && r != tick) r += spacing;
    }
}

contract AsymmetricFee_100bp_300bp_PoolsTest is AsymmetricFeePoolsTests, UsesHook_100bp_300bp {}

contract AsymmetricFee_300bp_100bp_PoolsTest is AsymmetricFeePoolsTests, UsesHook_300bp_100bp {}
