// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/fee/BaseOverrideFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title Strategy 08 accumulation hook
 * @notice A Uniswap v4 hook that sets the LP fee of every swap by direction only:
 *   - USDC in, STRK out (`zeroForOne == true`): 3% (30_000 hundredths of a bip);
 *   - STRK in, USDC out (`zeroForOne == false`): 1% (10_000 hundredths of a bip).
 * The fee goes to the pool's liquidity providers through v4's standard per-swap LP fee override. It is not a
 * separate charge, and the hook never holds or moves tokens. The fee ignores the sender, the amount, exact input
 * versus exact output, and hook data.
 *
 * Accepted pools: `currency0` is canonical Ethereum USDC, `currency1` is canonical Ethereum STRK, and the pool
 * key's fee is the dynamic fee flag. Pool initialization reverts for any other pool. Tick spacing is not
 * restricted.
 *
 * No change path: no owner, no setters, no storage variables, no upgrade proxy, no `delegatecall`, no oracle or
 * external lookup. The fees and token addresses are compile-time constants. The only constructor argument is the
 * pool manager.
 *
 * Builds on OpenZeppelin Uniswap Hooks v1.1.0 `BaseOverrideFee` (with its `BaseHook`). Of the published
 * OpenZeppelin audits, `BaseOverrideFee` is in the scope of the v1.0.0 audit only; `BaseHook` is also in the
 * scope of the v1.1.0 audits. THIS HOOK ITSELF IS UNAUDITED.
 *
 * @dev The deployment address must carry exactly the after-initialize and before-swap permission bits;
 * `BaseHook`'s constructor reverts otherwise.
 */
contract AccumulationHook is BaseOverrideFee {
    /// @notice Canonical Ethereum mainnet USDC. Sorts below STRK, so it is always `currency0`.
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Canonical Ethereum mainnet STRK. Always `currency1`.
    address public constant STRK = 0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766;

    /// @notice LP fee for USDC in, STRK out (`zeroForOne == true`): 3%, in hundredths of a bip.
    uint24 public constant USDC_TO_STRK_FEE = 30_000;

    /// @notice LP fee for STRK in, USDC out (`zeroForOne == false`): 1%, in hundredths of a bip.
    uint24 public constant STRK_TO_USDC_FEE = 10_000;

    /// @notice Pool initialization was attempted with currencies other than USDC (`currency0`) and STRK
    /// (`currency1`).
    error NotUsdcStrkPool(address currency0, address currency1);

    constructor(IPoolManager poolManager_) BaseOverrideFee(poolManager_) {}

    /**
     * @dev Refuses any pool that isn't USDC/STRK, then runs `BaseOverrideFee`'s check that the pool has the
     * dynamic fee flag (reverts `NotDynamicFee`). Reached only through `BaseHook.afterInitialize`, which is
     * restricted to the pool manager.
     */
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        if (Currency.unwrap(key.currency0) != USDC || Currency.unwrap(key.currency1) != STRK) {
            revert NotUsdcStrkPool(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
        }
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /**
     * @dev The fee for this swap, by direction only. `BaseOverrideFee._beforeSwap` returns it ORed with
     * `LPFeeLibrary.OVERRIDE_FEE_FLAG` and a zero delta. The pool is not re-checked here: the pool manager swaps
     * only in initialized pools, a pool's id covers its whole key (hook included), and every pool with this hook
     * was initialized through `_afterInitialize`.
     */
    function _getFee(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        pure
        override
        returns (uint24)
    {
        return params.zeroForOne ? USDC_TO_STRK_FEE : STRK_TO_USDC_FEE;
    }
}
