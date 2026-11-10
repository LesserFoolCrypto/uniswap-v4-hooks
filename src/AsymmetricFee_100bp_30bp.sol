// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AsymmetricFeeBase} from "./AsymmetricFeeBase.sol";

/**
 * @title Asymmetric Fee hook: 1% when token0 is paid in, 0.3% when token1 is paid in
 * @notice A Uniswap v4 hook that sets the LP fee of every swap by direction only:
 *   - token0 paid in, token1 out (`zeroForOne == true`): 1% (10_000 hundredths of a bip);
 *   - token1 paid in, token0 out (`zeroForOne == false`): 0.3% (3_000 hundredths of a bip).
 * Paying in token1 is cheaper, so the pool tends to collect token1.
 *
 * Naming rule: the first number is the fee when token0 is paid in, the second when token1 is paid in
 * (bp = basis points; 30bp = 0.3%, 100bp = 1%). v4 sorts a pool's two currencies by address, the lower being token0;
 * native ETH is always token0. The companion hook `AsymmetricFee_30bp_100bp` charges the reverse.
 *
 * Works with any two tokens, native ETH included, at any tick spacing, in pools whose key's fee is the dynamic fee
 * flag; pool initialization reverts for any other pool. Ethereum mainnet only: the pool manager is hard-coded to
 * Ethereum mainnet's Uniswap v4 PoolManager. No owner, no setters, no storage, nothing to change after deployment.
 * The fee rule and these limits are in `AsymmetricFeeBase`.
 *
 * Builds on OpenZeppelin Uniswap Hooks v1.1.0 `BaseOverrideFee`. THIS HOOK IS UNAUDITED.
 */
contract AsymmetricFee_100bp_30bp is AsymmetricFeeBase {
    constructor() AsymmetricFeeBase(10_000, 3_000) {}
}
