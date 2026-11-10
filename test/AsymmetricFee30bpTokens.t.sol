// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {AsymmetricFeeBase} from "../src/AsymmetricFeeBase.sol";
import {AsymmetricFee_100bp_30bp} from "../src/AsymmetricFee_100bp_30bp.sol";
import {
    AsymmetricFee30bpTestBase,
    UsesHook_30bp_100bp,
    UsesHook_100bp_30bp
} from "./utils/AsymmetricFee30bpTestBase.sol";

/**
 * @notice The fee follows token0 and token1, not a token; native ETH in swaps, to the wei; several pools on one hook
 * at once. Every swap is matched against its control pool (see `AsymmetricFee30bpTestBase`).
 */
abstract contract AsymmetricFee30bpTokensTests is AsymmetricFee30bpTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _initAndSeedAllPairs();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The fee follows token0 and token1
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev MID is token1 against LOW and token0 against HIGH. Paying in MID costs the token1-in fee on LOW/MID and
    /// the token0-in fee on MID/HIGH: the same token, two different fees, each the one the README table gives for its
    /// position. The partner tokens and ETH follow the same rule.
    function test_feeFollowsPositionNotToken() public {
        assertEq(_feeFor(true) == FEE_0_3PCT ? _feeFor(false) : _feeFor(true), FEE_1PCT, "one side 0.3%, the other 1%");

        // MID in.
        SwapResult memory onLowMid = _matchControl(LOW_MID, false, -10e18, "");
        SwapResult memory onMidHigh = _matchControl(MID_HIGH, true, -10e18, "");
        assertEq(onLowMid.delta1, -10e18, "LOW/MID: MID (token1) paid in");
        assertEq(onMidHigh.delta0, -10e18, "MID/HIGH: MID (token0) paid in");
        assertEq(onLowMid.eventFee, _token1InFee(), "MID as token1: token1-in fee");
        assertEq(onMidHigh.eventFee, _token0InFee(), "MID as token0: token0-in fee");
        assertTrue(onLowMid.eventFee != onMidHigh.eventFee, "same token, different fee");
        assertTrue(onLowMid.delta0 != onMidHigh.delta1, "and different amounts out at the same 1:1 price");

        // MID out, its partner in.
        assertEq(_matchControl(LOW_MID, true, -10e18, "").eventFee, _token0InFee(), "LOW (token0) in");
        assertEq(_matchControl(MID_HIGH, false, -10e18, "").eventFee, _token1InFee(), "HIGH (token1) in");

        // Native ETH is always token0.
        assertEq(_matchControl(ETH_MID, true, -1e18, "").eventFee, _token0InFee(), "ETH (token0) in");
        assertEq(_matchControl(ETH_MID, false, -1_000e18, "").eventFee, _token1InFee(), "MID (token1) in");
    }

    /// @dev At the same 1:1 price and the same position, paying in MID on the two pairs gives exactly what the two
    /// control pools give at the two different fees, for any amount.
    function testFuzz_sameTokenInBothPositions(uint256 amount, bool exactInput) public {
        amount = _bound(amount, 1, 500_000e18);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        assertEq(_matchControl(LOW_MID, false, specified, "").eventFee, _token1InFee());
        assertEq(_matchControl(MID_HIGH, true, specified, "").eventFee, _token0InFee());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Native ETH in swaps
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev ETH in as the call's value, ETH out as plain ETH, each amount proven to the wei: the trader's ETH change
    /// equals the `Swap` event's amount0 and is the opposite of the pool manager's ETH change (checked inside `_swap`),
    /// and the exactly specified side equals the specified amount. Gas price zero, so no gas in the ETH changes. After
    /// each swap the swap router holds zero ETH and the hook holds nothing (also inside `_swap`).
    function test_nativeEth_swapsToTheWei() public {
        assertEq(tx.gasprice, 0, "gas price");

        // ETH in, exact input: exactly the input is sent as value and taken.
        SwapResult memory r = _matchControl(ETH_MID, true, -2 ether, "");
        assertEq(r.delta0, -2 ether, "ETH paid in = exact input, to the wei");
        assertGt(r.delta1, 0);

        // ETH in, exact output: 100,000 ETH sent as value, the router returns what the pool did not take.
        r = _matchControl(ETH_MID, true, 3_000e18, "");
        assertEq(r.delta1, 3_000e18, "MID out = exact output");
        assertLt(r.delta0, 0);
        assertGt(r.delta0, -int256(ETH_FOR_EXACT_OUTPUT), "surplus returned");
        emit log_named_int("ETH paid in (wei) for exactly 3,000 MID out", r.delta0);

        // ETH out, exact input: plain ETH arrives at the trader, no claims.
        r = _matchControl(ETH_MID, false, -5_000e18, "");
        assertEq(r.delta1, -5_000e18);
        assertGt(r.delta0, 0, "ETH received");
        emit log_named_int("ETH received (wei) for 5,000 MID in", r.delta0);

        // ETH out, exact output.
        r = _matchControl(ETH_MID, false, 4 ether, "");
        assertEq(r.delta0, 4 ether, "ETH out = exact output, to the wei");
        assertLt(r.delta1, 0);

        assertEq(manager.balanceOf(trader, 0), 0, "no ETH claims: ETH was paid out as plain ETH");
        assertEq(address(swapRouter).balance, 0, "swap router holds no ETH");
        _assertHookHoldsNothing();
    }

    /// @dev The same with real swaps in a row (not reverted), checking the pool manager's ETH balance moves by
    /// exactly the trader's ETH change each time and adds up over the run.
    function test_nativeEth_runningTotal() public {
        uint256 managerBefore = address(manager).balance;
        uint256 traderBefore = trader.balance;
        int256 sum;
        PoolKey memory key = _hookedKey(ETH_MID);
        sum += _swap(key, true, -1 ether, MIN_PRICE_LIMIT, "").delta0;
        sum += _swap(key, false, -2_500e18, MAX_PRICE_LIMIT, "").delta0;
        sum += _swap(key, true, 777e18, MIN_PRICE_LIMIT, "").delta0;
        sum += _swap(key, false, 0.25 ether, MAX_PRICE_LIMIT, "").delta0;
        assertEq(int256(trader.balance) - int256(traderBefore), sum, "trader ETH");
        assertEq(int256(address(manager).balance) - int256(managerBefore), -sum, "pool manager ETH");
        assertEq(address(swapRouter).balance, 0);
        _assertHookHoldsNothing();
    }

    function testFuzz_nativeEth(bool zeroForOne, bool exactInput, uint256 amount) public {
        bool specifiedIsEth = zeroForOne == exactInput;
        amount = _bound(amount, 1, specifiedIsEth ? 500 ether : 500_000e18);
        SwapResult memory r = _matchControl(ETH_MID, zeroForOne, exactInput ? -int256(amount) : int256(amount), "");
        if (specifiedIsEth) assertEq(r.delta0, exactInput ? -int256(amount) : int256(amount), "ETH to the wei");
        assertEq(address(swapRouter).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Several pools on one hook at once
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Three live pools on the same hook (ETH/MID, LOW/MID, MID/HIGH). Twelve swaps interleaved across them,
    /// both directions, exact input and output. Each swap is matched against its own pair's control pool at the fee
    /// for its own direction (the controls are brought to the hooked pool's price after every swap); then the same
    /// swaps run pool by pool, one pool alone at a time, give exactly the same results: the pools do not affect each
    /// other through the hook.
    function test_threePoolsOnOneHook_interleaved() public {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            assertGt(manager.getLiquidity(_hookedKey(p).toId()), 0, "pool live");
            assertEq(address(_hookedKey(p).hooks), address(hook), "same hook");
        }
        uint256 snap = vm.snapshotState();
        SwapResult[12] memory interleaved;
        for (uint256 i; i < 12; ++i) {
            (uint256 p, bool zeroForOne, int256 amount) = _step(i);
            SwapResult memory expected = _matchControl(p, zeroForOne, amount, "");
            interleaved[i] = _swap(_hookedKey(p), zeroForOne, amount, _limit(zeroForOne), "");
            _assertSameSwap(interleaved[i], expected);
            assertEq(interleaved[i].eventFee, _feeFor(zeroForOne));
            _alignControlsWithHooked(p);
        }
        vm.revertToState(snap);
        for (uint256 p; p < PAIR_COUNT; ++p) {
            for (uint256 i; i < 12; ++i) {
                (uint256 q, bool zeroForOne, int256 amount) = _step(i);
                if (q != p) continue;
                _assertSameSwap(_swap(_hookedKey(p), zeroForOne, amount, _limit(zeroForOne), ""), interleaved[i]);
            }
        }
        _assertHookHoldsNothing();
    }

    /// @dev Step `i` of the interleaved run: pool i % 3; direction and mode from i, so each pool sees both
    /// directions and both modes; sizes vary.
    function _step(uint256 i) internal pure returns (uint256 p, bool zeroForOne, int256 amount) {
        p = i % PAIR_COUNT;
        zeroForOne = (i / PAIR_COUNT) % 2 == 0;
        bool exactInput = (i / (2 * PAIR_COUNT)) % 2 == 0;
        uint256 size = (i + 1) * 1e18;
        amount = exactInput ? -int256(size) : int256(size);
    }
}

contract AsymmetricFee_30bp_100bp_TokensTest is AsymmetricFee30bpTokensTests, UsesHook_30bp_100bp {}

contract AsymmetricFee_100bp_30bp_TokensTest is AsymmetricFee30bpTokensTests, UsesHook_100bp_30bp {}

/**
 * @notice Both hooks side by side on the same native-ETH pair, as the README's generic example describes: on
 * `AsymmetricFee_30bp_100bp` paying in ETH (token0) costs 0.3% and paying in the other token 1%; on
 * `AsymmetricFee_100bp_30bp` the reverse. Same pair, same price, same position, opposite fees.
 */
contract AsymmetricFee30bpBothHooksTest is AsymmetricFee30bpTestBase, UsesHook_30bp_100bp {
    AsymmetricFeeBase internal other;

    function setUp() public override {
        super.setUp();
        (bytes32 salt, address predicted) = _mineSalt(type(AsymmetricFee_100bp_30bp).creationCode, HOOK_FLAGS, 0);
        other = new AsymmetricFee_100bp_30bp{salt: salt}();
        assertEq(address(other), predicted);
        _initAndSeedPair(ETH_MID);
        _initAndSeed(ETH_MID, _otherKey());
    }

    function _otherKey() internal view returns (PoolKey memory) {
        return _key(ETH_MID, LPFeeLibrary.DYNAMIC_FEE_FLAG, address(other));
    }

    function test_sameEthPairOppositeFees() public {
        assertEq(hook.TOKEN0_IN_FEE(), FEE_0_3PCT);
        assertEq(hook.TOKEN1_IN_FEE(), FEE_1PCT);
        assertEq(other.TOKEN0_IN_FEE(), FEE_1PCT);
        assertEq(other.TOKEN1_IN_FEE(), FEE_0_3PCT);

        uint256 snap = vm.snapshotState();
        for (uint256 d; d < 2; ++d) {
            bool zeroForOne = d == 0;
            int256 amount = zeroForOne ? -int256(1 ether) : -int256(1_000e18);
            SwapResult memory a = _swap(_hookedKey(ETH_MID), zeroForOne, amount, _limit(zeroForOne), "");
            SwapResult memory b = _swap(_otherKey(), zeroForOne, amount, _limit(zeroForOne), "");
            vm.revertToState(snap);
            _assertSameSwap(
                a,
                _swap(
                    _staticKey(ETH_MID, zeroForOne ? FEE_0_3PCT : FEE_1PCT), zeroForOne, amount, _limit(zeroForOne), ""
                )
            );
            vm.revertToState(snap);
            _assertSameSwap(
                b,
                _swap(
                    _staticKey(ETH_MID, zeroForOne ? FEE_1PCT : FEE_0_3PCT), zeroForOne, amount, _limit(zeroForOne), ""
                )
            );
            vm.revertToState(snap);
            assertEq(a.eventFee, zeroForOne ? FEE_0_3PCT : FEE_1PCT, "30bp_100bp");
            assertEq(b.eventFee, zeroForOne ? FEE_1PCT : FEE_0_3PCT, "100bp_30bp");
        }
        _assertHookHoldsNothing();
        _assertHoldsNothing(address(other));
    }
}
