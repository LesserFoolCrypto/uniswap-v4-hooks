// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsymmetricFeeTestBase, UsesHook_100bp_300bp, UsesHook_300bp_100bp} from "./utils/AsymmetricFeeTestBase.sol";

/**
 * @notice The fee by direction, exact input and exact output, several sizes and fuzzed, on the native-ETH pair and
 * both two-token pairs; and hook data changes nothing. Each swap on the hooked pool is matched against the same swap
 * on the control pool with the static fee the hook should charge (same pair, price, tick spacing and position): the
 * trader's balance changes, the pool manager's `Swap` event and the pool's state afterwards must be identical, and
 * the event's fee must be the hook's fee for that direction.
 */
abstract contract AsymmetricFeeFeesTests is AsymmetricFeeTestBase {
    function setUp() public override {
        super.setUp();
        _initAndSeedAllPairs();
    }

    /// @dev Every pair, both directions, exact input and exact output, five sizes from 1 gwei to 100 units of the
    /// specified currency (for ETH, 100 ETH is a tenth of the pool's ETH).
    function test_feeByDirection_exactInputAndOutput_severalSizes() public {
        uint256[5] memory sizes = [uint256(1e9), 1e15, 1e18, 10e18, 100e18];
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                for (uint256 s; s < sizes.length; ++s) {
                    SwapResult memory r = _matchControl(p, zeroForOne, -int256(sizes[s]), "");
                    assertEq(zeroForOne ? r.delta0 : r.delta1, -int256(sizes[s]), "exact input paid in full");
                    r = _matchControl(p, zeroForOne, int256(sizes[s]), "");
                    assertEq(zeroForOne ? r.delta1 : r.delta0, int256(sizes[s]), "exact output received in full");
                }
            }
        }
    }

    /// @dev The comparison is sensitive: the same swap on the control pool at the other fee gives other amounts.
    function test_otherFeeWouldGiveOtherAmounts() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                SwapResult memory h = _matchControl(p, zeroForOne, -10e18, "");
                uint24 otherFee = _feeFor(zeroForOne) == FEE_1PCT ? FEE_3PCT : FEE_1PCT;
                uint256 snap = vm.snapshotState();
                SwapResult memory o = _swap(_staticKey(p, otherFee), zeroForOne, -10e18, _limit(zeroForOne), "");
                vm.revertToState(snap);
                if (zeroForOne) assertTrue(h.delta1 != o.delta1, "output differs at the other fee");
                else assertTrue(h.delta0 != o.delta0, "output differs at the other fee");
            }
        }
    }

    /// @dev The pool manager's `Swap` event reports the hook's fee for the direction, in all four modes, on every pair.
    function test_eventFeeIsTheDirectionFee() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            SwapResult memory r = _swap(_hookedKey(p), true, -1e18, MIN_PRICE_LIMIT, "");
            assertEq(r.eventFee, _feeFor(true));
            r = _swap(_hookedKey(p), false, -1e18, MAX_PRICE_LIMIT, "");
            assertEq(r.eventFee, _feeFor(false));
            r = _swap(_hookedKey(p), true, 1e15, MIN_PRICE_LIMIT, "");
            assertEq(r.eventFee, _feeFor(true));
            r = _swap(_hookedKey(p), false, 1e15, MAX_PRICE_LIMIT, "");
            assertEq(r.eventFee, _feeFor(false));
        }
    }

    /// @dev Any pair, direction, mode and size, up to swaps that use most of the pool.
    function testFuzz_feeMatchesControl(uint256 pairSeed, bool zeroForOne, bool exactInput, uint256 amount) public {
        uint256 p = pairSeed % PAIR_COUNT;
        // The specified currency is token0 for exact input of token0 or exact output of token0.
        bool specifiedIsToken0 = zeroForOne == exactInput;
        uint256 maxAmount = p == ETH_MID && specifiedIsToken0 ? 1_500 ether : 1_500_000e18;
        amount = _bound(amount, 1, maxAmount);
        _matchControl(p, zeroForOne, exactInput ? -int256(amount) : int256(amount), "");
    }

    /// @dev Several swaps in a row on the hooked pool, alternating direction, match the same swaps on a pool that
    /// switches between the control fees: each step is matched from the same state.
    function test_sequenceOfSwapsEachMatchesControl() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 i; i < 6; ++i) {
                bool zeroForOne = i % 2 == 0;
                int256 amount = -int256((i + 1) * 3e18);
                _matchControl(p, zeroForOne, amount, "");
                // Move the hooked pool on, then bring both control pools to its exact state for the next step.
                _swap(_hookedKey(p), zeroForOne, amount, _limit(zeroForOne), "");
                _alignControlsWithHooked(p);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hook data changes nothing
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Empty hook data, short data, a long payload and data that looks like a fee: identical results.
    function test_hookDataChangesNothing() public {
        bytes[4] memory data =
            [bytes(""), hex"c0ffee", abi.encode(uint24(1), uint24(500_000), address(this), "x"), new bytes(1_024)];
        data[3][0] = 0xff;
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 d; d < 2; ++d) {
                bool zeroForOne = d == 0;
                SwapResult memory first = _matchControl(p, zeroForOne, -5e18, data[0]);
                SwapResult memory firstOut = _matchControl(p, zeroForOne, 5e18, data[0]);
                for (uint256 i = 1; i < data.length; ++i) {
                    _assertSameSwap(_matchControl(p, zeroForOne, -5e18, data[i]), first);
                    _assertSameSwap(_matchControl(p, zeroForOne, 5e18, data[i]), firstOut);
                }
            }
        }
    }

    function testFuzz_hookDataChangesNothing(bytes calldata hookData, uint256 pairSeed, bool zeroForOne) public {
        uint256 p = pairSeed % PAIR_COUNT;
        _assertSameSwap(_matchControl(p, zeroForOne, -2e18, hookData), _matchControl(p, zeroForOne, -2e18, ""));
    }
}

contract AsymmetricFee_100bp_300bp_FeesTest is AsymmetricFeeFeesTests, UsesHook_100bp_300bp {}

contract AsymmetricFee_300bp_100bp_FeesTest is AsymmetricFeeFeesTests, UsesHook_300bp_100bp {}
