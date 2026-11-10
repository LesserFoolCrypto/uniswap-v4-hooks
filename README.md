# uniswap-v4-hooks

Source for the Uniswap v4 hooks deployed by LesserFoolCrypto on Ethereum mainnet. Every hook here is byte-for-byte the source that was deployed, comments included, and builds to the deployed code with the settings in `foundry.toml`.

**Unaudited.** Nothing here has been through a security audit. Use at your own risk.

| Hook | Address | What it does |
|---|---|---|
| [`AccumulationHook`](#accumulationhook) | [`0x38248A9A12F51858d872EE574C0B49c1D5A51080`](https://etherscan.io/address/0x38248a9a12f51858d872ee574c0b49c1d5a51080#code) | USDC/STRK only: 3% to buy STRK, 1% to sell it |
| [`AsymmetricFee_100bp_300bp`](#asymmetric-fee-hooks) | [`0x8d114c4e5f878c46827Db9c139585377a3009080`](https://etherscan.io/address/0x8d114c4e5f878c46827db9c139585377a3009080#code) | Any pair: 1% when token0 is paid in, 3% when token1 is paid in |
| [`AsymmetricFee_300bp_100bp`](#asymmetric-fee-hooks) | [`0x94B38AE9eFeaA84e50Cd715E51fec60114e11080`](https://etherscan.io/address/0x94b38ae9efeaa84e50cd715e51fec60114e11080#code) | Any pair: 3% when token0 is paid in, 1% when token1 is paid in |

All three are verified on Etherscan. Each sets the pool's LP fee per swap by direction, so the pool tends to collect the token that is cheaper to pay in. None can be changed: no owner, setters, storage, proxy or oracle.

## AccumulationHook

Deployed on Ethereum mainnet at [`0x38248A9A12F51858d872EE574C0B49c1D5A51080`](https://etherscan.io/address/0x38248a9a12f51858d872ee574c0b49c1d5a51080#code), source verified on Etherscan.

Source: [`src/AccumulationHook.sol`](src/AccumulationHook.sol). Tests: `test/AccumulationHook*.t.sol`.

What it does:

- Sets the LP fee of every swap by direction only. USDC in, STRK out (`zeroForOne == true`) pays 3% (`30_000`). STRK in, USDC out pays 1% (`10_000`). The fee goes to the pool's liquidity providers through v4's per-swap LP fee override. Sender, amount, exact input or output, and hook data make no difference.
- Accepts only pools where `currency0` is USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, `currency1` is STRK `0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766`, and the pool key's fee is the dynamic fee flag. Pool initialization reverts for anything else. Any tick spacing.
- Permissions: after-initialize and before-swap only, no return-delta flags.
- No change path: no owner, setters, storage variables, proxy, `delegatecall`, oracle, external call or token custody. Fees and token addresses are constants. The only constructor argument is the PoolManager (`0x000000000004444c5dc75cB358380D2e3dE08A90` on mainnet).
- Built on OpenZeppelin Uniswap Hooks v1.1.0 `BaseOverrideFee`. OpenZeppelin's audits cover that library, not this hook.

## Asymmetric Fee hooks

Two hooks that charge 1% one way and 3% the other on any Ethereum pair. The fees and the network are fixed in the code; the tokens are not.

| Hook | Fee when token0 is paid in | Fee when token1 is paid in | The pool tends to collect |
|---|---|---|---|
| `AsymmetricFee_100bp_300bp` | 1% (`10_000`) | 3% (`30_000`) | token0 |
| `AsymmetricFee_300bp_100bp` | 3% (`30_000`) | 1% (`10_000`) | token1 |

The name gives the fees in basis points: the first number is the fee when token0 is paid in, the second when token1 is paid in (100bp = 1%).

Source: [`src/AsymmetricFeeBase.sol`](src/AsymmetricFeeBase.sol) (the fee rule), [`src/AsymmetricFee_100bp_300bp.sol`](src/AsymmetricFee_100bp_300bp.sol) and [`src/AsymmetricFee_300bp_100bp.sol`](src/AsymmetricFee_300bp_100bp.sol) (each only sets its two fees). Tests: `test/AsymmetricFee*.t.sol`.

What they do:

- Set the LP fee of every swap from its direction only (`zeroForOne`). Sender, amount, exact input or output, and hook data make no difference. The fee goes to the pool's liquidity providers through v4's per-swap LP fee override.
- Accept any two tokens, native ETH included, and any tick spacing. The pool key's fee must be the dynamic fee flag (`0x800000`); initialization reverts otherwise, since v4 would ignore the hook's fee in a static-fee pool.
- Ethereum mainnet only: the PoolManager (`0x000000000004444c5dc75cB358380D2e3dE08A90`) is hard-coded, and every hook entry point refuses any other caller.
- Permissions: after-initialize and before-swap only, no return-delta flags.
- No change path: no owner, setters, storage variables, proxy, oracle, token custody, `receive`, `fallback` or withdrawal function. No constructor arguments.
- Uniswap governance can add a protocol fee of up to 0.1% per direction on top of the hook's fee. The hooks cannot prevent or change it.
- Built on OpenZeppelin Uniswap Hooks v1.1.0 `BaseOverrideFee`. OpenZeppelin's audits cover that library, not these hooks.

### Which hook do I use?

1. **Find token0.** v4 sorts a pool's two tokens by address; the lower address is token0. Native ETH (address zero) is always token0.
2. **Pick the hook whose cheap side is the token you want the pool to collect.** To collect token0, `AsymmetricFee_100bp_300bp`. To collect token1, `AsymmetricFee_300bp_100bp`.
3. **Watch ETH vs WETH.** On native ETH/USDC, `AsymmetricFee_100bp_300bp` charges 1% to pay in ETH and 3% to pay in USDC, so the pool tends to collect ETH. With WETH the order flips (USDC's address sorts below WETH's), so the other hook would be the one to pick.

### Setting up a pool

On app.uniswap.org: **New position**, pick the two tokens, **Add a hook** with the hook's address, and choose the **Dynamic fee tier**. Then set the range and amounts as usual.

**Check the starting price.** Anyone can create a pool on these hooks first, at any price. Before you deposit, compare the pool's current price with the market and use a slippage limit. If someone has created the pool at a bad price, create yours with another tick spacing instead.

## Build and test

Needs [Foundry](https://getfoundry.sh) 1.8.7 (other versions should compile the same bytecode, but 1.8.7 is what was used).

```sh
git clone --recurse-submodules https://github.com/LesserFoolCrypto/uniswap-v4-hooks
cd uniswap-v4-hooks
forge build
forge test
```

The tests deploy Uniswap's contracts locally. No fork and no RPC endpoint are needed.

To check the build against the deployed code (`sha256sum` of the hex that `jq` prints):

```sh
jq -r .deployedBytecode.object out/<Hook>.sol/<Hook>.json | sha256sum
jq -r .bytecode.object out/<Hook>.sol/<Hook>.json | sha256sum
```

| Hook | Runtime | Creation |
|---|---|---|
| `AccumulationHook` | `1f795972d46d66fdd6d9862bd09976711701dc415946e3862509be3000d56651` | `2342e08101433f89a9713da572d74fc1e6007c51284e39945f753c00716974c9` |
| `AsymmetricFee_100bp_300bp` | `0fa0edf59c6527dd2e495072b6a35ee4e298cebc8c15065d4768f0a334bcfa48` | `b8d9ec7263cdd2fba1973944906c8571bfc0d8be6ea9bb18c77245123d92face` |
| `AsymmetricFee_300bp_100bp` | `9fa269d262d6b8631fb1870f5d4f3fe9536d028690b69715480eb6783a87f267` | `eff00c53953d30a068d909332d82debf08464af43ec666428ccd6b1ec8a38c54` |

The code on chain differs from `deployedBytecode` only where immutables are stored: the PoolManager address for all three, and the two fees for the Asymmetric Fee hooks. With those filled in, the runtime code hashes (`EXTCODEHASH`) are `0xc89a3a900804e32ecb9f914a2753a6e6f4c4450375a5f99a144c5b0ee075ad60` (`AsymmetricFee_100bp_300bp`) and `0x94961b95ce0f54f1089d32b211a44770b4d0cdc8dee733138f1300b71b0e2210` (`AsymmetricFee_300bp_100bp`), the same as on mainnet.

## Pinned dependencies

Git submodules in `lib/`, shared by all the hooks. The folder names, the commits and the source paths under `src/` are part of what the bytecode commits to, so don't rename or bump them.

| Folder in `lib/` | Repository | Commit |
|---|---|---|
| `v4-core` | Uniswap/v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` |
| `v4-periphery` | Uniswap/v4-periphery | `545a5d2a87228167edde48f3b9eda122d1e3c4d6` |
| `universal-router` | Uniswap/universal-router (2.1.2) | `802fe4c18f47300e0f183e2a42e9146ec2ea9fc3` |
| `openzeppelin-uniswap-hooks` | OpenZeppelin/uniswap-hooks (v1.1.0) | `e59fe72c110c3862eec9b332530dce49ca506bbb` |
| `forge-std` | foundry-rs/forge-std | `1de6eecf821de7fe2c908cc48d3ab3dced20717f` |
| `solmate` (tests only) | transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` |
| `permit2` (tests only) | Uniswap/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` |
| `@openzeppelin` (tests only) | OpenZeppelin/openzeppelin-contracts | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` |

Compiler: solc `0.8.26+commit.8a97fa7a`, EVM `cancun`, optimizer on with 200 runs, no `via_ir`, IPFS metadata hash.

## License

MIT. See [LICENSE](LICENSE).
