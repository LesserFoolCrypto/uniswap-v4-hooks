// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";

import {AsymmetricFeeTestBase, UsesHook_100bp_300bp, UsesHook_300bp_100bp} from "./utils/AsymmetricFeeTestBase.sol";

/**
 * @notice Liquidity through v4-periphery's `PositionManager`: add, increase after fees have built up, reduce, collect
 * and full removal, with native ETH sent as value and the unused part swept back in the same call, and ETH paid out
 * as plain ETH. Every call checks, inside the base's helpers: the LP's change in each currency equals what v4's own
 * math says (principal at the current price plus earned fees) to the wei, the pool manager's change is exactly the
 * opposite, and the `PositionManager` and the swap router hold exactly zero ETH afterwards. The LP earns the hook's
 * fee for each direction in the currency paid in; the hook never blocks a withdrawal (it has no liquidity
 * permissions, so the pool manager never calls it during liquidity changes).
 */
abstract contract AsymmetricFeeLiquidityTests is AsymmetricFeeTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        for (uint256 p; p < PAIR_COUNT; ++p) {
            manager.initialize(_hookedKey(p), _sqrtInit(p));
            manager.initialize(_staticKey(p, FEE_1PCT), _sqrtInit(p));
            manager.initialize(_staticKey(p, FEE_3PCT), _sqrtInit(p));
        }
    }

    /// @dev One native-ETH position through its whole life on the hooked pool.
    function test_nativeEth_lifecycle() public {
        PoolKey memory key = _hookedKey(ETH_MID);
        uint128 liquidity = pairs[ETH_MID].liquidity;

        // Add: ETH as value, 1 ETH more than needed, swept back in the same call (checked to the wei in `_mint`).
        uint256 ethBefore = lp.balance;
        (uint256 id, int256 paid0,) = _mint(lp, key, pairs[ETH_MID].tickLower, pairs[ETH_MID].tickUpper, liquidity);
        assertEq(lp.balance, ethBefore - uint256(-paid0), "LP paid exactly the ETH the position needs");
        emit log_named_int("ETH paid for the position (wei)", paid0);

        // ETH (token0) in: the LP earns the token0-in fee on it, in ETH, and nothing in MID.
        _swap(key, true, -10 ether, MIN_PRICE_LIMIT, "");
        _assertCollectedFee(id, 10 ether, true);
        // MID (token1) in: the token1-in fee, in MID, and nothing in ETH.
        _swap(key, false, -10_000e18, MAX_PRICE_LIMIT, "");
        _assertCollectedFee(id, 10_000e18, false);
        // Exact output pays the same rates on its (computed) input.
        SwapResult memory r = _swap(key, true, 5_000e18, MIN_PRICE_LIMIT, "");
        _assertCollectedFee(id, uint256(-r.delta0), true);
        r = _swap(key, false, 2 ether, MAX_PRICE_LIMIT, "");
        _assertCollectedFee(id, uint256(-r.delta1), false);

        // Fees build up in both currencies; then an increase that needs less ETH than the ETH fees earned.
        _swap(key, true, -300 ether, MIN_PRICE_LIMIT, "");
        _swap(key, false, -300_000e18, MAX_PRICE_LIMIT, "");
        uint128 small = liquidity / 10_000;
        (, int256 e0,) = _expectedChange(id, int128(small));
        assertGt(e0, 0, "ETH fees exceed the ETH the increase needs");
        _assertSettlePairWouldRevert(id, small);
        (int256 d0, int256 d1) = _increase(lp, id, small);
        assertGt(d0, 0, "LP receives the surplus ETH as plain ETH; the 1 ETH sent came back too");
        emit log_named_int("increase after fees: LP's net ETH change (wei)", d0);
        emit log_named_int("increase after fees: LP's net MID change (base units)", d1);

        // An increase that needs more than the fees: the LP pays the difference, the surplus value comes back.
        (d0,) = _increase(lp, id, liquidity / 2);
        assertLt(d0, 0);
        uint128 current = posm.getPositionLiquidity(id);
        assertEq(current, liquidity + small + liquidity / 2);

        // Reduce by a third: plain ETH back.
        ethBefore = lp.balance;
        (uint256 got0, uint256 got1) = _decrease(lp, id, current / 3);
        assertGt(got0, 0);
        assertGt(got1, 0);
        assertEq(lp.balance, ethBefore + got0, "plain ETH received");
        assertEq(manager.balanceOf(lp, 0), 0, "no ETH claims");
        assertEq(posm.getPositionLiquidity(id), current - current / 3);

        // Fees from one more swap, collect, then full removal.
        _swap(key, true, -1 ether, MIN_PRICE_LIMIT, "");
        _collect(lp, id);
        (got0, got1) = _burn(lp, id);
        assertGt(got0, 0);
        assertGt(got1, 0);
        assertEq(manager.getLiquidity(key.toId()), 0, "pool empty");
        // All that is left in the pool manager is rounding dust (this is the only pool with liquidity here).
        assertLe(address(manager).balance, 10, "ETH dust");
        assertLe(IERC20(TOKEN_MID).balanceOf(address(manager)), 10, "MID dust");
        assertEq(address(posm).balance, 0);
        assertEq(address(swapRouter).balance, 0);
        _assertHookHoldsNothing();
    }

    /// @dev One two-token position on the hook: add, collect each side's fee, full removal.
    function test_twoTokenPosition_addCollectRemove() public {
        PoolKey memory key = _hookedKey(LOW_MID);
        (uint256 id,,) = _mint(lp, key, pairs[LOW_MID].tickLower, pairs[LOW_MID].tickUpper, pairs[LOW_MID].liquidity);
        _swap(key, true, -20_000e18, MIN_PRICE_LIMIT, "");
        _assertCollectedFee(id, 20_000e18, true);
        _swap(key, false, -30_000e18, MAX_PRICE_LIMIT, "");
        _assertCollectedFee(id, 30_000e18, false);
        _swap(key, true, -5_000e18, MIN_PRICE_LIMIT, "");
        (uint256 got0, uint256 got1) = _burn(lp, id);
        assertGt(got0, 0);
        assertGt(got1, 0);
        assertEq(manager.getLiquidity(key.toId()), 0);
        assertLe(IERC20(TOKEN_LOW).balanceOf(address(manager)), 10, "LOW dust");
        assertLe(IERC20(TOKEN_MID).balanceOf(address(manager)), 10, "MID dust");
        _assertHookHoldsNothing();
    }

    /// @dev The LP of the hooked pool earns exactly what the LP of the matching control pool earns from the same
    /// swap, on any pair, in all four modes and at any size, and withdraws exactly the same.
    function testFuzz_lpFeesEqualControlLp(uint256 pairSeed, bool zeroForOne, bool exactInput, uint256 amount)
        public
    {
        uint256 p = pairSeed % PAIR_COUNT;
        bool specifiedIsToken0 = zeroForOne == exactInput;
        amount = _bound(amount, 1, p == ETH_MID && specifiedIsToken0 ? 1_500 ether : 1_500_000e18);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        PoolKey memory control = _controlKey(p, zeroForOne);
        (uint256 hookedId,,) = _mint(lp, _hookedKey(p), pairs[p].tickLower, pairs[p].tickUpper, pairs[p].liquidity);
        (uint256 controlId,,) = _mint(lp, control, pairs[p].tickLower, pairs[p].tickUpper, pairs[p].liquidity);

        _assertSameSwap(
            _swap(_hookedKey(p), zeroForOne, specified, _limit(zeroForOne), ""),
            _swap(control, zeroForOne, specified, _limit(zeroForOne), "")
        );
        (uint256 h0, uint256 h1) = _collect(lp, hookedId);
        (uint256 c0, uint256 c1) = _collect(lp, controlId);
        assertEq(h0, c0, "currency0 fees");
        assertEq(h1, c1, "currency1 fees");
        // Fees only in the currency paid in.
        if (zeroForOne) assertEq(h1, 0);
        else assertEq(h0, 0);

        (h0, h1) = _burn(lp, hookedId);
        (c0, c1) = _burn(lp, controlId);
        assertEq(h0, c0, "currency0 withdrawn");
        assertEq(h1, c1, "currency1 withdrawn");
        _assertHookHoldsNothing();
    }

    /// @dev Withdrawal works wherever the price ends up: below the range (position all ETH) and above it (all MID),
    /// after the swaps that moved it there.
    function test_nativeEth_fullWithdrawalAfterPriceLeavesRangeBothWays() public {
        PoolKey memory key = _hookedKey(ETH_MID);
        int24 lower = pairs[ETH_MID].tickLower;
        int24 upper = pairs[ETH_MID].tickUpper;
        (uint256 id,,) = _mint(lp, key, lower, upper, pairs[ETH_MID].liquidity);
        _swap(key, true, -5_000 ether, TickMath.getSqrtPriceAtTick(lower - 600), "");
        (, int24 tick,,) = manager.getSlot0(key.toId());
        assertLt(tick, lower);
        (uint256 got0, uint256 got1) = _burn(lp, id);
        assertGt(got0, 1_000 ether, "all ETH: principal, swapped-in ETH and fees");
        assertLe(got1, 1, "no MID left in the position");

        // The price is below the range, so the new position is all ETH; MID in pushes the price above the range.
        int256 ethPaid;
        (id, ethPaid,) = _mint(lp, key, lower, upper, pairs[ETH_MID].liquidity);
        assertLt(ethPaid, 0);
        _swap(key, false, -50_000_000e18, TickMath.getSqrtPriceAtTick(upper + 600), "");
        (, tick,,) = manager.getSlot0(key.toId());
        assertGt(tick, upper);
        (got0, got1) = _burn(lp, id);
        assertLe(got0, 1, "no ETH left in the position");
        assertGt(got1, 0);
        _assertHookHoldsNothing();
    }

    /// @dev Two LPs with different ranges on the native-ETH pool, many swaps both ways, then each withdraws
    /// everything, in either order.
    function testFuzz_nativeEth_twoLpsWithdrawInAnyOrder(bool secondFirst, uint256 seed) public {
        address lp2 = makeAddr("lp2");
        _fund(lp2);
        PoolKey memory key = _hookedKey(ETH_MID);
        (uint256 id1,,) = _mint(lp, key, pairs[ETH_MID].tickLower, pairs[ETH_MID].tickUpper, pairs[ETH_MID].liquidity);
        (uint256 id2,,) =
            _mint(lp2, key, ETH_MID_TICK - 1_200, ETH_MID_TICK + 2_400, pairs[ETH_MID].liquidity / 3);

        for (uint256 i; i < 6; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            if (x % 2 == 0) _swap(key, true, -int256(_bound(x, 1e12, 300 ether)), MIN_PRICE_LIMIT, "");
            else _swap(key, false, -int256(_bound(x, 1e15, 300_000e18)), MAX_PRICE_LIMIT, "");
        }

        if (secondFirst) {
            _burn(lp2, id2);
            _burn(lp, id1);
        } else {
            _burn(lp, id1);
            _burn(lp2, id2);
        }
        assertEq(manager.getLiquidity(key.toId()), 0);
        _assertHookHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Collect and check the LP got the hook's fee for the direction on `paidIn`, in the currency paid in, within
    /// 3 base units of rounding (v4 rounds the fee up when charging and fee growth down when crediting), and nothing in
    /// the other currency. The position is the pool's only liquidity, so it earns the whole LP fee.
    function _assertCollectedFee(uint256 id, uint256 paidIn, bool zeroForOne) internal {
        (uint256 got0, uint256 got1) = _collect(lp, id);
        uint256 expected = paidIn * _feeFor(zeroForOne) / 1e6;
        if (zeroForOne) {
            assertApproxEqAbs(got0, expected, 3, "fee in token0");
            assertEq(got1, 0, "no token1 fee from token0-in swaps");
        } else {
            assertApproxEqAbs(got1, expected, 3, "fee in token1");
            assertEq(got0, 0, "no token0 fee from token1-in swaps");
        }
    }

    /// @dev Why the increase uses `CLOSE_CURRENCY`: with `SETTLE_PAIR` the same increase reverts, because the ETH
    /// delta is a credit (fees exceed what the increase needs) and `SETTLE_PAIR` settles debts only.
    function _assertSettlePairWouldRevert(uint256 id, uint128 liquidity) internal {
        (PoolKey memory key,,) = _expectedChange(id, int128(liquidity));
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(id, uint256(liquidity), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, lp);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(DeltaResolver.DeltaNotNegative.selector, key.currency0));
        posm.modifyLiquidities{value: ETH_EXTRA}(abi.encode(actions, params), block.timestamp);
    }
}

contract AsymmetricFee_100bp_300bp_LiquidityTest is AsymmetricFeeLiquidityTests, UsesHook_100bp_300bp {}

contract AsymmetricFee_300bp_100bp_LiquidityTest is AsymmetricFeeLiquidityTests, UsesHook_300bp_100bp {}
