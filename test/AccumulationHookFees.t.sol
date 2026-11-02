// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {AccumulationHookTestBase} from "./utils/AccumulationHookTestBase.sol";

/**
 * @notice Commission S08-M1-015, section 5 items 1 and 6: the fee in both directions, exact input and exact output,
 * proven from balance changes, a static-fee control pool, a zero-fee reference pool and the `Swap` event; and hook
 * data.
 */
contract AccumulationHookFeesTest is AccumulationHookTestBase {
    function setUp() public override {
        super.setUp();
        _initAndSeed(hookedKey);
        _initAndSeed(static3Key);
        _initAndSeed(static1Key);
        _initAndSeed(zeroFeeKey);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Same amounts as a static-fee pool at the matching fee (3% USDC in, 1% STRK in), several sizes
    // ---------------------------------------------------------------------------------------------------------------

    function test_usdcToStrk_exactInput_matchesStatic3Pool() public {
        uint256[5] memory usdcIn = [uint256(1e6), 250e6, 10_000e6, 400_000e6, 1_200_000e6];
        for (uint256 i; i < usdcIn.length; ++i) {
            _assertMatchesControl(true, -int256(usdcIn[i]));
        }
    }

    function test_usdcToStrk_exactOutput_matchesStatic3Pool() public {
        uint256[5] memory strkOut = [uint256(8e18), 2_000e18, 80_000e18, 3_000_000e18, 7_000_000e18];
        for (uint256 i; i < strkOut.length; ++i) {
            _assertMatchesControl(true, int256(strkOut[i]));
        }
    }

    function test_strkToUsdc_exactInput_matchesStatic1Pool() public {
        uint256[5] memory strkIn = [uint256(8e18), 2_000e18, 80_000e18, 3_000_000e18, 9_000_000e18];
        for (uint256 i; i < strkIn.length; ++i) {
            _assertMatchesControl(false, -int256(strkIn[i]));
        }
    }

    function test_strkToUsdc_exactOutput_matchesStatic1Pool() public {
        uint256[5] memory usdcOut = [uint256(1e6), 250e6, 10_000e6, 400_000e6, 900_000e6];
        for (uint256 i; i < usdcOut.length; ++i) {
            _assertMatchesControl(false, int256(usdcOut[i]));
        }
    }

    /// @dev Any direction, mode and size, including sizes past the position's range (partial fills).
    function testFuzz_matchesStaticPool(bool zeroForOne, bool exactInput, uint256 amount) public {
        // The amount is in USDC for USDC in (exact input) or USDC out (exact output), otherwise in STRK.
        amount = _bound(amount, 1, zeroForOne == exactInput ? 2_000_000e6 : 16_000_000e18);
        _assertMatchesControl(zeroForOne, exactInput ? -int256(amount) : int256(amount));
    }

    /// @dev The comparison has teeth: the static pool at the other fee gives different amounts.
    function test_wrongFeeControlDiffers() public {
        uint256 snap = vm.snapshotState();
        SwapResult memory hooked = _swap(hookedKey, true, -10_000e6, MIN_PRICE_LIMIT, "");
        vm.revertToState(snap);
        SwapResult memory at1 = _swap(static1Key, true, -10_000e6, MIN_PRICE_LIMIT, "");
        vm.revertToState(snap);
        assertLt(hooked.strkDelta, at1.strkDelta, "3% gives less STRK than 1%");

        hooked = _swap(hookedKey, false, -80_000e18, MAX_PRICE_LIMIT, "");
        vm.revertToState(snap);
        SwapResult memory at3 = _swap(static3Key, false, -80_000e18, MAX_PRICE_LIMIT, "");
        vm.revertToState(snap);
        assertGt(hooked.usdcDelta, at3.usdcDelta, "1% gives more USDC than 3%");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Fee computed from balances against a zero-fee reference pool
    // ---------------------------------------------------------------------------------------------------------------

    function test_feeFromZeroFeeReference_fixedSizes() public {
        _assertFeeAgainstZeroFeePool(true, true, 100e6);
        _assertFeeAgainstZeroFeePool(true, true, 250_000e6);
        _assertFeeAgainstZeroFeePool(true, false, 800e18);
        _assertFeeAgainstZeroFeePool(true, false, 2_000_000e18);
        _assertFeeAgainstZeroFeePool(false, true, 800e18);
        _assertFeeAgainstZeroFeePool(false, true, 2_000_000e18);
        _assertFeeAgainstZeroFeePool(false, false, 100e6);
        _assertFeeAgainstZeroFeePool(false, false, 250_000e6);
    }

    /// @dev Sizes that stay inside the position's range, so the whole exact input is used.
    function testFuzz_feeFromZeroFeeReference(bool zeroForOne, bool exactInput, uint256 amount) public {
        if (zeroForOne == exactInput) amount = _bound(amount, 0.1e6, 500_000e6);
        else amount = _bound(amount, 1e18, 4_000_000e18);
        _assertFeeAgainstZeroFeePool(zeroForOne, exactInput, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The hook's own return value (supporting check only; the proofs above do not rely on it)
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzz_beforeSwapReturnValue(
        address sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit,
        bytes calldata hookData
    ) public {
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook.beforeSwap(
            sender,
            hookedKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            hookData
        );
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, (zeroForOne ? FEE_USDC_TO_STRK : FEE_STRK_TO_USDC) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hook data (item 6)
    // ---------------------------------------------------------------------------------------------------------------

    function test_emptyHookData_allFourModesSucceed() public {
        uint256 snap = vm.snapshotState();
        assertEq(_swap(hookedKey, true, -1_000e6, MIN_PRICE_LIMIT, "").eventFee, FEE_USDC_TO_STRK);
        vm.revertToState(snap);
        assertEq(_swap(hookedKey, true, 8_000e18, MIN_PRICE_LIMIT, "").eventFee, FEE_USDC_TO_STRK);
        vm.revertToState(snap);
        assertEq(_swap(hookedKey, false, -8_000e18, MAX_PRICE_LIMIT, "").eventFee, FEE_STRK_TO_USDC);
        vm.revertToState(snap);
        assertEq(_swap(hookedKey, false, 1_000e6, MAX_PRICE_LIMIT, "").eventFee, FEE_STRK_TO_USDC);
        vm.revertToState(snap);
    }

    function testFuzz_hookDataChangesNothing(bytes calldata hookData, bool zeroForOne, bool exactInput, uint256 amount)
        public
    {
        vm.assume(hookData.length > 0);
        amount = _bound(amount, 1, zeroForOne == exactInput ? 2_000_000e6 : 16_000_000e18);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        uint256 snap = vm.snapshotState();
        SwapResult memory empty = _swap(hookedKey, zeroForOne, specified, _limit(zeroForOne), "");
        vm.revertToState(snap);
        SwapResult memory withData = _swap(hookedKey, zeroForOne, specified, _limit(zeroForOne), hookData);
        _assertSameSwap(empty, withData);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev The same swap on the hooked pool and on the static pool at the expected fee: identical balance changes,
    /// event amounts, price, tick and liquidity after, and `Swap` event fee 30,000 (USDC in) or 10,000 (STRK in).
    function _assertMatchesControl(bool zeroForOne, int256 amountSpecified) internal {
        uint24 fee = zeroForOne ? FEE_USDC_TO_STRK : FEE_STRK_TO_USDC;
        uint256 snap = vm.snapshotState();
        SwapResult memory hooked = _swap(hookedKey, zeroForOne, amountSpecified, _limit(zeroForOne), "");
        vm.revertToState(snap);
        SwapResult memory control =
            _swap(zeroForOne ? static3Key : static1Key, zeroForOne, amountSpecified, _limit(zeroForOne), "");
        vm.revertToState(snap);

        assertEq(hooked.eventFee, fee, "hooked pool Swap event fee");
        assertEq(control.eventFee, fee, "control pool Swap event fee");
        _assertSameSwap(hooked, control);
        // Direction: USDC in and STRK out when zeroForOne, and the reverse otherwise.
        if (zeroForOne) {
            assertLe(hooked.usdcDelta, 0);
            assertGe(hooked.strkDelta, 0);
        } else {
            assertLe(hooked.strkDelta, 0);
            assertGe(hooked.usdcDelta, 0);
        }
        _assertHookHoldsNothing();
    }

    /// @dev Swap on the hooked pool, then ask the zero-fee pool (same state) for exactly the same output. The input
    /// the zero-fee pool needs is the swap's input net of fee, so the fee paid is the difference. v4 charges the LP
    /// fee on the input: fee = net * f / (1e6 - f), which is gross * f / 1e6.
    /// Tolerance: for exact output both pools move the price identically, so only per-step rounding (a few base
    /// units) differs. For exact input the hooked swap's output is rounded down, so the zero-fee input can be lower
    /// by up to one output base unit's worth of input: about 8e12 STRK base units (one USDC base unit) when STRK is
    /// the input, under one USDC base unit the other way.
    function _assertFeeAgainstZeroFeePool(bool zeroForOne, bool exactInput, uint256 amount) internal {
        uint24 fee = zeroForOne ? FEE_USDC_TO_STRK : FEE_STRK_TO_USDC;
        uint256 snap = vm.snapshotState();
        SwapResult memory hooked =
            _swap(hookedKey, zeroForOne, exactInput ? -int256(amount) : int256(amount), _limit(zeroForOne), "");
        vm.revertToState(snap);
        (uint256 grossIn, uint256 out) = zeroForOne
            ? (uint256(-hooked.usdcDelta), uint256(hooked.strkDelta))
            : (uint256(-hooked.strkDelta), uint256(hooked.usdcDelta));
        if (exactInput) assertEq(grossIn, amount, "whole exact input used");
        else assertEq(out, amount, "whole exact output delivered");

        SwapResult memory zeroFee = _swap(zeroFeeKey, zeroForOne, int256(out), _limit(zeroForOne), "");
        vm.revertToState(snap);
        assertEq(zeroFee.eventFee, 0);
        uint256 netIn = zeroForOne ? uint256(-zeroFee.usdcDelta) : uint256(-zeroFee.strkDelta);
        assertEq(zeroForOne ? uint256(zeroFee.strkDelta) : uint256(zeroFee.usdcDelta), out, "same output");

        uint256 feePaid = grossIn - netIn;
        uint256 tolerance = exactInput ? (zeroForOne ? 4 : 2e13) : 4;
        assertApproxEqAbs(feePaid, netIn * fee / (1e6 - fee), tolerance, "fee = net * f / (1e6 - f)");
        assertApproxEqAbs(feePaid, grossIn * fee / 1e6, tolerance + 1, "fee = gross * f / 1e6");
    }
}
