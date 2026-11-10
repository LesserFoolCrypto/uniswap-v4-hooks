// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseOverrideFee} from "@openzeppelin/uniswap-hooks/fee/BaseOverrideFee.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title Asymmetric Fee hook base
 * @notice Shared fee rule of the two Asymmetric Fee hooks, `AsymmetricFee_100bp_300bp` and
 * `AsymmetricFee_300bp_100bp`. A Uniswap v4 hook built on this base sets the LP fee of every swap by direction only:
 *   - token0 paid in (`zeroForOne == true`): `TOKEN0_IN_FEE`;
 *   - token1 paid in (`zeroForOne == false`): `TOKEN1_IN_FEE`.
 * Fees are in hundredths of a bip (10_000 = 1%). The fee goes to the pool's liquidity providers through v4's
 * standard per-swap LP fee override. It is not a separate charge, and the hook never holds or moves tokens or ETH.
 * The fee ignores the tokens, the sender, the amount, exact input versus exact output, and hook data.
 *
 * Accepted pools: any pool whose key's fee is the dynamic fee flag. Any two tokens, native ETH included, and any
 * tick spacing. Pool initialization reverts for a pool without the dynamic fee flag, since v4 ignores the override
 * in such a pool and it would silently charge its static fee.
 *
 * Ethereum mainnet only: the pool manager is hard-coded to Ethereum mainnet's Uniswap v4 PoolManager
 * (`POOL_MANAGER`), and every hook entry point refuses any other caller. On any other chain no PoolManager can call
 * the hook, so it does nothing there.
 *
 * No change path: no owner, no setters, no storage variables, no upgrade proxy, no `delegatecall`, no oracle or
 * external lookup, no `receive` or `fallback`, no withdrawal function. The fees are fixed at deployment by the
 * concrete hook, which takes no constructor arguments.
 *
 * Builds on OpenZeppelin Uniswap Hooks v1.1.0 `BaseOverrideFee` (with its `BaseHook`). Of the published
 * OpenZeppelin audits, `BaseOverrideFee` is in the scope of the v1.0.0 audit only; `BaseHook` is also in the
 * scope of the v1.1.0 audits. THESE HOOKS THEMSELVES ARE UNAUDITED.
 *
 * @dev The deployment address must carry exactly the after-initialize and before-swap permission bits;
 * `BaseHook`'s constructor reverts otherwise.
 */
abstract contract AsymmetricFeeBase is BaseOverrideFee {
    /// @notice Ethereum mainnet's Uniswap v4 PoolManager, the only caller the hook answers. `poolManager()`, inherited
    /// from `BaseHook`, returns the same address.
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    /// @notice LP fee when token0 is paid in (`zeroForOne == true`), in hundredths of a bip.
    uint24 public immutable TOKEN0_IN_FEE;

    /// @notice LP fee when token1 is paid in (`zeroForOne == false`), in hundredths of a bip.
    uint24 public immutable TOKEN1_IN_FEE;

    /// @dev Called only by the concrete hooks, each with its two fixed fees. Immutables live in the deployed code,
    /// not in storage.
    constructor(uint24 token0InFee, uint24 token1InFee) BaseOverrideFee(POOL_MANAGER) {
        TOKEN0_IN_FEE = token0InFee;
        TOKEN1_IN_FEE = token1InFee;
    }

    /**
     * @dev The fee for this swap, by direction only. `BaseOverrideFee._beforeSwap` returns it ORed with
     * `LPFeeLibrary.OVERRIDE_FEE_FLAG` and a zero delta. The pool is not re-checked here: the pool manager swaps
     * only in initialized pools, a pool's id covers its whole key (hook included), and every pool with this hook
     * was initialized through `BaseOverrideFee._afterInitialize`, which refuses pools without the dynamic fee flag.
     */
    function _getFee(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return params.zeroForOne ? TOKEN0_IN_FEE : TOKEN1_IN_FEE;
    }
}
