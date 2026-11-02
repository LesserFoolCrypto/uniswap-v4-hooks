// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/fee/BaseOverrideFee.sol";

import {AccumulationHook} from "../src/AccumulationHook.sol";
import {AccumulationHookTestBase} from "./utils/AccumulationHookTestBase.sol";

/**
 * @notice Commission S08-M1-015, section 5 items 2 and 3, and the "invalid fee setup" case of item 7: token order,
 * and which pools the hook accepts, tried directly on the pool manager. Hook reverts arrive wrapped by the pool
 * manager: `WrappedError(hook, IHooks.afterInitialize.selector, reason, HookCallFailed())`.
 */
contract AccumulationHookPoolsTest is AccumulationHookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant NATIVE_ETH = address(0);
    address internal constant LOW_TOKEN = 0x0000000000000000000000000000000000001111;
    address internal constant HIGH_TOKEN = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;

    // ---------------------------------------------------------------------------------------------------------------
    // Item 2: token order
    // ---------------------------------------------------------------------------------------------------------------

    function test_tokenOrder_usdcIsCurrency0() public {
        assertEq(hook.USDC(), USDC, "hook USDC = canonical USDC");
        assertEq(hook.STRK(), STRK, "hook STRK = canonical STRK");
        assertLt(uint160(USDC), uint160(STRK), "USDC sorts below STRK");
        assertEq(Currency.unwrap(hookedKey.currency0), USDC);
        assertEq(Currency.unwrap(hookedKey.currency1), STRK);
        assertEq(IERC20(USDC).decimals(), 6);
        assertEq(IERC20(STRK).decimals(), 18);

        // zeroForOne == true is USDC in, STRK out, at 3%; false is STRK in, USDC out, at 1%.
        _initAndSeed(hookedKey);
        SwapResult memory r = _swap(hookedKey, true, -100e6, MIN_PRICE_LIMIT, "");
        assertEq(r.usdcDelta, -100e6);
        assertGt(r.strkDelta, 0);
        assertEq(r.eventFee, FEE_USDC_TO_STRK);
        r = _swap(hookedKey, false, -800e18, MAX_PRICE_LIMIT, "");
        assertEq(r.strkDelta, -800e18);
        assertGt(r.usdcDelta, 0);
        assertEq(r.eventFee, FEE_STRK_TO_USDC);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Item 3: accepted pools, at more than one tick spacing
    // ---------------------------------------------------------------------------------------------------------------

    function test_initialize_acceptsUsdcStrkDynamicAtManyTickSpacings() public {
        int24[8] memory spacings = [int24(1), 10, 60, 100, 200, 1_000, 16_384, TickMath.MAX_TICK_SPACING];
        for (uint256 i; i < spacings.length; ++i) {
            PoolKey memory key = _keyWithSpacing(spacings[i]);
            int24 tick = manager.initialize(key, sqrtPriceInit);
            assertEq(tick, INIT_TICK);
            (uint160 sqrtPriceX96,, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
            assertEq(sqrtPriceX96, sqrtPriceInit);
            assertEq(protocolFee, 0);
            assertEq(lpFee, 0, "stored LP fee of a dynamic pool starts at 0");
        }
    }

    function testFuzz_initialize_acceptsAnyTickSpacing(int24 spacing) public {
        spacing = int24(_bound(int256(spacing), TickMath.MIN_TICK_SPACING, TickMath.MAX_TICK_SPACING));
        manager.initialize(_keyWithSpacing(spacing), sqrtPriceInit);
    }

    /// @dev The fee does not depend on the tick spacing: swaps at spacings 10 and 200 match the static pools there.
    function test_feeSameAtOtherTickSpacings() public {
        int24[2] memory spacings = [int24(10), 200];
        for (uint256 i; i < spacings.length; ++i) {
            int24 spacing = spacings[i];
            PoolKey memory hooked = _keyWithSpacing(spacing);
            PoolKey memory s3 = static3Key;
            PoolKey memory s1 = static1Key;
            s3.tickSpacing = spacing;
            s1.tickSpacing = spacing;
            // The standard range, widened to the nearest multiples of the spacing (both ticks are positive).
            int24 lower = TICK_LOWER / spacing * spacing;
            int24 upper = (TICK_UPPER + spacing - 1) / spacing * spacing;
            PoolKey[3] memory keys = [hooked, s3, s1];
            for (uint256 k; k < keys.length; ++k) {
                manager.initialize(keys[k], sqrtPriceInit);
                _mint(lp, keys[k], lower, upper, positionLiquidity);
            }

            uint256 snap = vm.snapshotState();
            SwapResult memory h = _swap(hooked, true, -5_000e6, MIN_PRICE_LIMIT, "");
            vm.revertToState(snap);
            _assertSameSwap(h, _swap(s3, true, -5_000e6, MIN_PRICE_LIMIT, ""));
            assertEq(h.eventFee, FEE_USDC_TO_STRK);
            vm.revertToState(snap);
            h = _swap(hooked, false, -40_000e18, MAX_PRICE_LIMIT, "");
            vm.revertToState(snap);
            _assertSameSwap(h, _swap(s1, false, -40_000e18, MAX_PRICE_LIMIT, ""));
            assertEq(h.eventFee, FEE_STRK_TO_USDC);
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Item 3: refused pools, called on the pool manager directly
    // ---------------------------------------------------------------------------------------------------------------

    function test_initialize_rejectsOtherPairs() public {
        address[2][8] memory pairs = [
            [USDC, WETH],
            [USDC, USDT],
            [USDC, HIGH_TOKEN],
            [NATIVE_ETH, USDC],
            [NATIVE_ETH, STRK],
            [WETH, STRK],
            [LOW_TOKEN, STRK],
            [LOW_TOKEN, HIGH_TOKEN]
        ];
        for (uint256 i; i < pairs.length; ++i) {
            _expectPairRejected(pairs[i][0], pairs[i][1], LPFeeLibrary.DYNAMIC_FEE_FLAG);
        }
        // The pair check comes first: a wrong pair with a static fee also reports the pair.
        _expectPairRejected(USDC, WETH, 3_000);
    }

    function testFuzz_initialize_rejectsAnyOtherPair(address a, address b) public {
        vm.assume(a != b);
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        vm.assume(!(c0 == USDC && c1 == STRK));
        _expectPairRejected(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG);
    }

    /// @dev v4 sorts currencies, so "STRK/USDC" cannot be expressed as a pool. A key naming STRK as currency0 still
    /// fails: in the reverse order the pool manager refuses it, and with any token above STRK the hook does.
    function test_initialize_rejectsStrkAsCurrency0() public {
        PoolKey memory key = hookedKey;
        key.currency0 = Currency.wrap(STRK);
        key.currency1 = Currency.wrap(USDC);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesOutOfOrderOrEqual.selector, STRK, USDC));
        manager.initialize(key, sqrtPriceInit);

        key.currency1 = Currency.wrap(STRK);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.CurrenciesOutOfOrderOrEqual.selector, STRK, STRK));
        manager.initialize(key, sqrtPriceInit);

        _expectPairRejected(STRK, HIGH_TOKEN, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        _expectPairRejected(STRK, address(uint160(STRK) + 1), LPFeeLibrary.DYNAMIC_FEE_FLAG);
    }

    /// @dev Right pair, no dynamic fee flag: refused (item 3, and item 7 "invalid fee setup").
    function test_initialize_rejectsStaticFee() public {
        uint24[9] memory fees = [uint24(0), 1, 100, 500, 3_000, 10_000, 30_000, 100_000, 1_000_000];
        for (uint256 i; i < fees.length; ++i) {
            PoolKey memory key = hookedKey;
            key.fee = fees[i];
            vm.expectRevert(
                _wrappedHookError(
                    IHooks.afterInitialize.selector, abi.encodeWithSelector(BaseOverrideFee.NotDynamicFee.selector)
                )
            );
            manager.initialize(key, sqrtPriceInit);
        }
    }

    /// @dev Every fee value except the dynamic flag itself is refused: by the hook when it is a valid static fee, by
    /// the pool manager (`LPFeeTooLarge`) when it is not a valid fee at all, such as the flag with other bits set.
    function testFuzz_initialize_rejectsAnyFeeButDynamicFlag(uint24 fee) public {
        vm.assume(fee != LPFeeLibrary.DYNAMIC_FEE_FLAG);
        PoolKey memory key = hookedKey;
        key.fee = fee;
        if (fee > LPFeeLibrary.MAX_LP_FEE) {
            vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, fee));
        } else {
            vm.expectRevert(
                _wrappedHookError(
                    IHooks.afterInitialize.selector, abi.encodeWithSelector(BaseOverrideFee.NotDynamicFee.selector)
                )
            );
        }
        manager.initialize(key, sqrtPriceInit);
    }

    /// @dev A refused key leaves no pool behind: swaps on it revert in the pool manager.
    function test_swapOnRefusedKeyReverts() public {
        _placeToken(WETH, "WETH", 18); // the swap router reads balances before it swaps
        PoolKey memory wrongPair = hookedKey;
        wrongPair.currency1 = Currency.wrap(WETH);
        _expectPairRejected(USDC, WETH, LPFeeLibrary.DYNAMIC_FEE_FLAG);
        PoolKey memory staticFee = hookedKey;
        staticFee.fee = 30_000;
        vm.expectRevert();
        manager.initialize(staticFee, sqrtPriceInit);

        vm.startPrank(trader);
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        swapRouter.swap(
            wrongPair,
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.expectRevert(IPoolManager.PoolNotInitialized.selector);
        swapRouter.swap(
            staticFee,
            SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _keyWithSpacing(int24 spacing) internal view returns (PoolKey memory key) {
        key = hookedKey;
        key.tickSpacing = spacing;
    }

    function _expectPairRejected(address c0, address c1, uint24 fee) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(
            _wrappedHookError(
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(AccumulationHook.NotUsdcStrkPool.selector, c0, c1)
            )
        );
        manager.initialize(key, sqrtPriceInit);
    }
}
