// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    AsymmetricFee30bpTestBase,
    UsesHook_30bp_100bp,
    UsesHook_100bp_30bp
} from "./utils/AsymmetricFee30bpTestBase.sol";

/**
 * @notice Both hooks with a protocol fee on, both directions, on the native-ETH pair and both two-token pairs.
 *
 * Uniswap's governance can switch on a protocol fee on any pool, up to 1000 pips (0.1%) per direction, on top of the
 * LP fee the hook sets. The hook cannot prevent or change it. Then, in v4-core at the pin:
 * - the swap fee, and the `Swap` event's fee field, is the combined fee
 *   `protocolFee + lpFee - protocolFee * lpFee / 1e6`, the division rounded down
 *   (`ProtocolFeeLibrary.calculateSwapFee`, `Pool.swap`);
 * - the protocol takes `input * protocolFee / 1e6` of an exact input (rounded down), and the LP the rest of the fee,
 *   `input * (combinedFee - protocolFee) / 1e6` (`Pool.swap`: the protocol's share comes off the step's fee);
 * - the hooked pool still matches, to the wei, its control pool: the static pool at the fee the hook should charge,
 *   with the same protocol fee.
 * Here the protocol fee is 1000 pips when currency0 is paid in and 500 when currency1 is paid in, so a swapped half
 * would show. Combined fees: `AsymmetricFee_30bp_100bp` 3997 (token0 in) and 10495 (token1 in);
 * `AsymmetricFee_100bp_30bp` 10990 and 3499.
 *
 * The rounding matters on one side. With 500 pips on the 0.3% fee, `500 * 3000 / 1e6` is 1.5, rounded down to 1: the
 * combined fee is 3499 and the LP keeps 2999 pips of the input, half a pip more than
 * `lpFee * (1e6 - protocolFee) / 1e6` (2998.5). That form is exact only when `protocolFee * lpFee` is a whole multiple
 * of 1e6, as it is for every other side here (`test_lpShareUsesTheRoundedCombinedFee`).
 */
abstract contract AsymmetricFee30bpProtocolFeeTests is AsymmetricFee30bpTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint24 internal constant PROTOCOL_FEE_ZERO_FOR_ONE = 1000;
    uint24 internal constant PROTOCOL_FEE_ONE_FOR_ZERO = 500;

    /// @dev How far the LP's share may differ from the formula, in base units of the currency paid in: the fee is
    /// rounded in each step of the swap loop, the protocol's share once more (down), the fee growth counter once
    /// (down) and the position's fees once more (down).
    uint256 internal constant ROUNDING_TOLERANCE = 3;

    address internal controller;
    uint256[PAIR_COUNT] internal hookedTokenIds;

    function setUp() public override {
        super.setUp();
        for (uint256 p; p < PAIR_COUNT; ++p) {
            hookedTokenIds[p] = _initAndSeedPair(p);
        }
        // The PoolManager's owner names a protocol fee controller; only the controller sets a pool's protocol fee.
        controller = makeAddr("protocolFeeController");
        vm.prank(v4Owner);
        manager.setProtocolFeeController(controller);
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _setProtocolFee(p, PROTOCOL_FEE_ZERO_FOR_ONE, PROTOCOL_FEE_ONE_FOR_ZERO);
        }
    }

    /// @dev The same protocol fee on the hooked pool of pair `p` and on both its control pools.
    function _setProtocolFee(uint256 p, uint24 zeroForOneFee, uint24 oneForZeroFee) internal {
        uint24 packed = zeroForOneFee | (oneForZeroFee << 12);
        PoolKey[3] memory keys = [_hookedKey(p), _staticKey(p, FEE_0_3PCT), _staticKey(p, FEE_1PCT)];
        for (uint256 i; i < keys.length; ++i) {
            vm.prank(controller);
            manager.setProtocolFee(keys[i], packed);
        }
    }

    function _combinedFee(uint24 protocolFee, uint24 lpFee) internal pure returns (uint24) {
        return uint24(uint256(protocolFee) + lpFee - uint256(protocolFee) * lpFee / 1_000_000);
    }

    /// @dev The protocol fee reads back per direction, on every hooked pool: the low 12 bits for currency0 paid in.
    function test_protocolFeeIsSetPerDirection() public view {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            (,, uint24 protocolFee,) = manager.getSlot0(_hookedKey(p).toId());
            assertEq(protocolFee & 0xfff, PROTOCOL_FEE_ZERO_FOR_ONE, "currency0 in");
            assertEq(protocolFee >> 12, PROTOCOL_FEE_ONE_FOR_ZERO, "currency1 in");
        }
    }

    /// @dev The combined fees, written out from the formula for this hook's two fees.
    function test_combinedFeesAreTheFormulasForThisHook() public pure {
        uint24 zeroForOne = _combinedFee(PROTOCOL_FEE_ZERO_FOR_ONE, _feeFor(true));
        uint24 oneForZero = _combinedFee(PROTOCOL_FEE_ONE_FOR_ZERO, _feeFor(false));
        assertEq(zeroForOne, ProtocolFeeLibrary.calculateSwapFee(uint16(PROTOCOL_FEE_ZERO_FOR_ONE), _feeFor(true)));
        assertEq(oneForZero, ProtocolFeeLibrary.calculateSwapFee(uint16(PROTOCOL_FEE_ONE_FOR_ZERO), _feeFor(false)));
        if (_feeFor(true) == FEE_0_3PCT) {
            assertEq(zeroForOne, 3_997);
            assertEq(oneForZero, 10_495);
        } else {
            assertEq(zeroForOne, 10_990);
            assertEq(oneForZero, 3_499);
        }
    }

    /// @dev Every pair, both directions, three exact-input sizes: the event's fee is the combined fee; the protocol's
    /// share and the LP's share are v4-core's formulas; the hooked pool matches its control pool to the wei.
    function test_exactInput_eventFeeProtocolShareAndLpShare() public {
        uint256[3] memory sizes = [uint256(1e15), 1e18, 10e18];
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 d; d < 2; ++d) {
                for (uint256 s; s < sizes.length; ++s) {
                    _checkExactInput(p, d == 0, sizes[s]);
                }
            }
        }
    }

    /// @dev Exact output too: the event's fee is the combined fee and the hooked pool matches its control pool.
    function test_exactOutput_eventFeeAndControl() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                SwapResult memory h = _hookedMatchesControl(p, zeroForOne, 1e18);
                assertEq(h.eventFee, _combinedFee(_protocolFeeFor(zeroForOne), _feeFor(zeroForOne)), "combined fee");
            }
        }
    }

    /// @dev Any protocol fee v4 allows (0 to 1000 pips each way), any pair and direction: the event's fee is the
    /// combined fee (the LP fee alone when the protocol fee is 0) and the hooked pool matches its control pool.
    function testFuzz_anyProtocolFee_eventFeeIsCombinedAndMatchesControl(
        uint16 zeroForOneFee,
        uint16 oneForZeroFee,
        uint256 pairSeed,
        bool zeroForOne,
        uint256 amount
    ) public {
        uint24 f0 = uint24(_bound(zeroForOneFee, 0, 1000));
        uint24 f1 = uint24(_bound(oneForZeroFee, 0, 1000));
        uint256 p = pairSeed % PAIR_COUNT;
        amount = _bound(amount, 1e6, 50e18);
        _setProtocolFee(p, f0, f1);
        uint24 protocolFee = zeroForOne ? f0 : f1;
        SwapResult memory h = _hookedMatchesControl(p, zeroForOne, -int256(amount));
        uint24 expected = protocolFee == 0 ? _feeFor(zeroForOne) : _combinedFee(protocolFee, _feeFor(zeroForOne));
        assertEq(h.eventFee, expected, "event fee");
    }

    /// @dev The LP's share is `input * (combinedFee - protocolFee) / 1e6`, with v4-core's rounded combined fee. Where
    /// `protocolFee * lpFee` is a whole multiple of 1e6 this equals `input * lpFee * (1e6 - protocolFee) / 1e12`. Where
    /// it is not (500 pips on the 0.3% fee: `AsymmetricFee_100bp_30bp` with token1 in), the LP gets
    /// `input * (protocolFee * lpFee % 1e6) / 1e12` more than that form: for 10 tokens of 18 decimals, 5e12 base
    /// units, far beyond rounding. On the two-token pair LOW/MID, both directions.
    function test_lpShareUsesTheRoundedCombinedFee() public {
        uint256 amountIn = 10e18;
        for (uint256 d; d < 2; ++d) {
            bool zeroForOne = d == 0;
            uint256 lpFee = _feeFor(zeroForOne);
            uint256 protocolFee = _protocolFeeFor(zeroForOne);
            uint256 rounded = amountIn * (_combinedFee(uint24(protocolFee), uint24(lpFee)) - protocolFee) / 1_000_000;
            uint256 unrounded = amountIn * lpFee * (1_000_000 - protocolFee) / 1e12;
            uint256 remainder = protocolFee * lpFee % 1_000_000;

            uint256 snap = vm.snapshotState();
            Shares memory got = _swapAndMeasure(LOW_MID, zeroForOne, amountIn);
            vm.revertToState(snap);

            assertApproxEqAbs(got.lp, rounded, ROUNDING_TOLERANCE, "LP share = input x (combined - protocol) / 1e6");
            assertEq(rounded - unrounded, amountIn * remainder / 1e12, "the two forms differ by the remainder");
            if (remainder == 0) {
                assertEq(rounded, unrounded, "whole product: the two forms agree");
            } else {
                assertGt(got.lp, unrounded + ROUNDING_TOLERANCE, "the unrounded form misses the LP's share");
            }
            emit log_named_uint(
                zeroForOne ? "token0 in: LP share (base units)" : "token1 in: LP share (base units)", got.lp
            );
            emit log_named_uint("  input x (combined - protocol) / 1e6", rounded);
            emit log_named_uint("  input x LP fee x (1e6 - protocol) / 1e12", unrounded);
        }
        // Of the four sides of the two hooks, only `AsymmetricFee_100bp_30bp` with token1 in has a remainder.
        assertEq(uint256(PROTOCOL_FEE_ZERO_FOR_ONE) * _feeFor(true) % 1_000_000, 0, "token0 in: whole");
        assertEq(
            uint256(PROTOCOL_FEE_ONE_FOR_ZERO) * _feeFor(false) % 1_000_000 != 0,
            _feeFor(false) == FEE_0_3PCT,
            "token1 in: a remainder exactly when the token1-in fee is 0.3%"
        );
    }

    function _protocolFeeFor(bool zeroForOne) internal pure returns (uint24) {
        return zeroForOne ? PROTOCOL_FEE_ZERO_FOR_ONE : PROTOCOL_FEE_ONE_FOR_ZERO;
    }

    /// @dev One exact-input swap of `amountIn` on the hooked pool of pair `p`, checked:
    /// - the trader paid exactly `amountIn` (and `_swap` checks the trader's and the PoolManager's balances against
    ///   the event to the wei);
    /// - the event's fee is the combined fee, by the formula and by v4-core's own library;
    /// - the PoolManager's `protocolFeesAccrued` in the currency paid in rose by `amountIn * protocolFee / 1e6`;
    /// - the LP's position earned `amountIn * (combinedFee - protocolFee) / 1e6` in that currency (within the stated
    ///   rounding), and nothing in the other;
    /// - the same swap on the control pool gives the same amounts, price, liquidity, tick and event fee.
    function _checkExactInput(uint256 p, bool zeroForOne, uint256 amountIn) internal {
        uint24 lpFee = _feeFor(zeroForOne);
        uint24 protocolFee = _protocolFeeFor(zeroForOne);

        uint256 snap = vm.snapshotState();
        Shares memory got = _swapAndMeasure(p, zeroForOne, amountIn);
        vm.revertToState(snap);
        SwapResult memory c = _swap(_controlKey(p, zeroForOne), zeroForOne, -int256(amountIn), _limit(zeroForOne), "");
        vm.revertToState(snap);

        SwapResult memory h = got.swap;
        _assertSameSwap(h, c);
        assertEq(zeroForOne ? h.delta0 : h.delta1, -int256(amountIn), "exact input paid in full");
        assertEq(h.eventFee, _combinedFee(protocolFee, lpFee), "event fee = protocol + LP - protocol x LP / 1e6");
        assertEq(h.eventFee, ProtocolFeeLibrary.calculateSwapFee(uint16(protocolFee), lpFee), "v4-core's formula");
        assertEq(got.protocol, amountIn * protocolFee / 1_000_000, "protocol share = input x protocol fee / 1e6");
        assertApproxEqAbs(
            got.lp,
            amountIn * (_combinedFee(protocolFee, lpFee) - protocolFee) / 1_000_000,
            ROUNDING_TOLERANCE,
            "LP share = input x (combined fee - protocol fee) / 1e6"
        );
        assertEq(got.lpOther, 0, "no LP fee in the currency paid out");
    }

    /// @dev What one exact-input swap on the hooked pool gave: the swap itself, the protocol's share (the rise in the
    /// PoolManager's `protocolFeesAccrued` in the currency paid in) and the LP position's fees in each currency.
    struct Shares {
        SwapResult swap;
        uint256 protocol;
        uint256 lp;
        uint256 lpOther;
    }

    function _swapAndMeasure(uint256 p, bool zeroForOne, uint256 amountIn) internal returns (Shares memory r) {
        PoolKey memory key = _hookedKey(p);
        Currency paidIn = zeroForOne ? key.currency0 : key.currency1;
        (uint256 owed0Before, uint256 owed1Before) = _feesOwed(key, hookedTokenIds[p]);
        uint256 protocolBefore = manager.protocolFeesAccrued(paidIn);
        r.swap = _swap(key, zeroForOne, -int256(amountIn), _limit(zeroForOne), "");
        (uint256 owed0After, uint256 owed1After) = _feesOwed(key, hookedTokenIds[p]);
        r.protocol = manager.protocolFeesAccrued(paidIn) - protocolBefore;
        r.lp = zeroForOne ? owed0After - owed0Before : owed1After - owed1Before;
        r.lpOther = zeroForOne ? owed1After - owed1Before : owed0After - owed0Before;
    }

    /// @dev The same swap on the hooked pool and on the control pool from the same state; leaves the state as it was.
    function _hookedMatchesControl(uint256 p, bool zeroForOne, int256 amountSpecified)
        internal
        returns (SwapResult memory h)
    {
        uint256 snap = vm.snapshotState();
        h = _swap(_hookedKey(p), zeroForOne, amountSpecified, _limit(zeroForOne), "");
        vm.revertToState(snap);
        SwapResult memory c = _swap(_controlKey(p, zeroForOne), zeroForOne, amountSpecified, _limit(zeroForOne), "");
        vm.revertToState(snap);
        _assertSameSwap(h, c);
    }
}

contract AsymmetricFee_30bp_100bp_ProtocolFeeTest is AsymmetricFee30bpProtocolFeeTests, UsesHook_30bp_100bp {}

contract AsymmetricFee_100bp_30bp_ProtocolFeeTest is AsymmetricFee30bpProtocolFeeTests, UsesHook_100bp_30bp {}
