// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {AccumulationHookTestBase} from "./utils/AccumulationHookTestBase.sol";

/**
 * @notice Commission S08-M1-015, section 5 item 5: add, increase, reduce, collect and fully remove liquidity through
 * v4-periphery's `PositionManager` (with Permit2). The LP earns 3% of the USDC paid in USDC-to-STRK swaps, in USDC,
 * and 1% of the STRK paid in STRK-to-USDC swaps, in STRK; the hook never holds tokens and never blocks a withdrawal.
 */
contract AccumulationHookLiquidityTest is AccumulationHookTestBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        manager.initialize(hookedKey, sqrtPriceInit);
        manager.initialize(static3Key, sqrtPriceInit);
        manager.initialize(static1Key, sqrtPriceInit);
    }

    /// @dev One position through its whole life on the hooked pool.
    function test_lifecycle_mintCollectIncreaseReduceBurn() public {
        (uint256 id, uint256 paidUsdc, uint256 paidStrk) =
            _mint(lp, hookedKey, TICK_LOWER, TICK_UPPER, positionLiquidity);
        assertEq(posm.ownerOf(id), lp);
        assertEq(posm.getPositionLiquidity(id), positionLiquidity);
        assertApproxEqRel(paidUsdc, LP_USDC, 0.001e18);
        assertGt(paidStrk, 0);

        // USDC -> STRK, 50,000 USDC in: the LP's fee is 3% of it, 1,500 USDC, and no STRK.
        _swap(hookedKey, true, -50_000e6, MIN_PRICE_LIMIT, "");
        (uint256 feeUsdc, uint256 feeStrk) = _collect(lp, id);
        assertApproxEqAbs(feeUsdc, 1_500e6, 3, "3% of USDC in, in USDC");
        assertEq(feeStrk, 0, "no STRK fee from USDC-in swaps");
        emit log_named_uint("LP fee collected, USDC base units, from 50,000 USDC in", feeUsdc);
        (feeUsdc, feeStrk) = _collect(lp, id);
        assertEq(feeUsdc + feeStrk, 0, "collected once only");

        // STRK -> USDC, 400,000 STRK in: 1% of it, 4,000 STRK, and no USDC.
        _swap(hookedKey, false, -400_000e18, MAX_PRICE_LIMIT, "");
        (feeUsdc, feeStrk) = _collect(lp, id);
        assertEq(feeUsdc, 0, "no USDC fee from STRK-in swaps");
        assertApproxEqAbs(feeStrk, 4_000e18, 3, "1% of STRK in, in STRK");
        emit log_named_uint("LP fee collected, STRK base units, from 400,000 STRK in", feeStrk);

        // Exact output swaps pay the same rates on their (computed) input.
        SwapResult memory r = _swap(hookedKey, true, 100_000e18, MIN_PRICE_LIMIT, "");
        (feeUsdc, feeStrk) = _collect(lp, id);
        assertApproxEqAbs(feeUsdc, uint256(-r.usdcDelta) * 30_000 / 1e6, 3);
        assertEq(feeStrk, 0);
        r = _swap(hookedKey, false, 10_000e6, MAX_PRICE_LIMIT, "");
        (feeUsdc, feeStrk) = _collect(lp, id);
        assertEq(feeUsdc, 0);
        assertApproxEqAbs(feeStrk, uint256(-r.strkDelta) * 10_000 / 1e6, 3);

        // Increase by half.
        _increase(lp, id, positionLiquidity / 2);
        uint128 liquidity = posm.getPositionLiquidity(id);
        assertEq(liquidity, positionLiquidity + positionLiquidity / 2);

        // Reduce by a third.
        (uint256 gotUsdc, uint256 gotStrk) = _decrease(lp, id, liquidity / 3);
        assertGt(gotUsdc, 0);
        assertGt(gotStrk, 0);
        assertEq(posm.getPositionLiquidity(id), liquidity - liquidity / 3);

        // Fees from a further swap, then full removal by burning the position.
        _swap(hookedKey, true, -20_000e6, MIN_PRICE_LIMIT, "");
        (gotUsdc, gotStrk) = _burn(lp, id);
        assertGt(gotUsdc, 0);
        assertGt(gotStrk, 0);
        assertEq(manager.getLiquidity(hookedKey.toId()), 0, "pool empty");
        vm.expectRevert(bytes("NOT_MINTED"));
        posm.ownerOf(id);

        // All that is left in the pool manager is rounding dust (this is the only pool with liquidity here).
        assertLe(IERC20(USDC).balanceOf(address(manager)), 10, "USDC dust");
        assertLe(IERC20(STRK).balanceOf(address(manager)), 10, "STRK dust");
        _assertHookHoldsNothing();
    }

    /// @dev The LP of the hooked pool earns exactly what the LP of the matching static-fee pool earns from the same
    /// swap, in all four modes and at any size.
    function testFuzz_lpFeesEqualStaticPoolLp(bool zeroForOne, bool exactInput, uint256 amount) public {
        amount = _bound(amount, 1, zeroForOne == exactInput ? 2_000_000e6 : 16_000_000e18);
        int256 specified = exactInput ? -int256(amount) : int256(amount);
        PoolKey memory control = zeroForOne ? static3Key : static1Key;
        (uint256 hookedId,,) = _mint(lp, hookedKey, TICK_LOWER, TICK_UPPER, positionLiquidity);
        (uint256 controlId,,) = _mint(lp, control, TICK_LOWER, TICK_UPPER, positionLiquidity);

        _assertSameSwap(
            _swap(hookedKey, zeroForOne, specified, _limit(zeroForOne), ""),
            _swap(control, zeroForOne, specified, _limit(zeroForOne), "")
        );
        (uint256 hUsdc, uint256 hStrk) = _collect(lp, hookedId);
        (uint256 cUsdc, uint256 cStrk) = _collect(lp, controlId);
        assertEq(hUsdc, cUsdc, "USDC fees");
        assertEq(hStrk, cStrk, "STRK fees");
        // Fees only in the input token.
        if (zeroForOne) assertEq(hStrk, 0);
        else assertEq(hUsdc, 0);

        (uint256 hOut0, uint256 hOut1) = _burn(lp, hookedId);
        (uint256 cOut0, uint256 cOut1) = _burn(lp, controlId);
        assertEq(hOut0, cOut0, "USDC withdrawn");
        assertEq(hOut1, cOut1, "STRK withdrawn");
        _assertHookHoldsNothing();
    }

    /// @dev Withdrawal works wherever the price ends up: below the range (position all USDC) and above it (all
    /// STRK), after the swaps that moved it there.
    function test_fullWithdrawal_afterPriceLeavesRangeBothWays() public {
        (uint256 id,,) = _mint(lp, hookedKey, TICK_LOWER, TICK_UPPER, positionLiquidity);
        _swap(hookedKey, true, -5_000_000e6, TickMath.getSqrtPriceAtTick(TICK_LOWER - 600), "");
        (, int24 tick,,) = manager.getSlot0(hookedKey.toId());
        assertLt(tick, TICK_LOWER);
        (uint256 gotUsdc, uint256 gotStrk) = _burn(lp, id);
        assertGt(gotUsdc, LP_USDC, "all USDC: principal, swapped-in USDC and fees");
        assertLe(gotStrk, 1, "no STRK left in the position");

        (id,,) = _mint(lp, hookedKey, TICK_LOWER, TICK_UPPER, positionLiquidity);
        // The price is below the range, so the new position is all USDC; STRK in pushes the price above the range.
        _swap(hookedKey, false, -50_000_000e18, TickMath.getSqrtPriceAtTick(TICK_UPPER + 600), "");
        (, tick,,) = manager.getSlot0(hookedKey.toId());
        assertGt(tick, TICK_UPPER);
        (gotUsdc, gotStrk) = _burn(lp, id);
        assertLe(gotUsdc, 1, "no USDC left in the position");
        assertGt(gotStrk, 0);
        _assertHookHoldsNothing();
    }

    /// @dev Two LPs with different ranges, many swaps both ways, then each withdraws everything, in either order.
    function testFuzz_twoLpsWithdrawInAnyOrder(bool secondFirst, uint256 seed) public {
        address lp2 = makeAddr("lp2");
        _fund(lp2, 100 * LP_USDC, 100 * LP_STRK);
        _approvePosm(lp2);
        (uint256 id1,,) = _mint(lp, hookedKey, TICK_LOWER, TICK_UPPER, positionLiquidity);
        (uint256 id2,,) = _mint(lp2, hookedKey, INIT_TICK - 1_200, INIT_TICK + 2_400, positionLiquidity / 3);

        for (uint256 i; i < 6; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            if (x % 2 == 0) _swap(hookedKey, true, -int256(_bound(x, 1e6, 300_000e6)), MIN_PRICE_LIMIT, "");
            else _swap(hookedKey, false, -int256(_bound(x, 8e18, 2_400_000e18)), MAX_PRICE_LIMIT, "");
        }

        if (secondFirst) {
            _burn(lp2, id2);
            _burn(lp, id1);
        } else {
            _burn(lp, id1);
            _burn(lp2, id2);
        }
        assertEq(manager.getLiquidity(hookedKey.toId()), 0);
        _assertHookHoldsNothing();
    }
}
