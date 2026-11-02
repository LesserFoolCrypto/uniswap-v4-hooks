# uniswap-v4-hooks

Source for Uniswap v4 hooks deployed by LesserFoolCrypto. One hook so far.

**Unaudited.** Nothing here has been through a security audit. Use at your own risk.

## AccumulationHook

Deployed on Ethereum mainnet at [`0x38248A9A12F51858d872EE574C0B49c1D5A51080`](https://etherscan.io/address/0x38248a9a12f51858d872ee574c0b49c1d5a51080#code), source verified on Etherscan.

Source: [`src/AccumulationHook.sol`](src/AccumulationHook.sol). This file is byte-for-byte the source that was deployed, comments included, and the build settings in `foundry.toml` are the ones it was built with.

What it does:

- Sets the LP fee of every swap by direction only. USDC in, STRK out (`zeroForOne == true`) pays 3% (`30_000`). STRK in, USDC out pays 1% (`10_000`). The fee goes to the pool's liquidity providers through v4's per-swap LP fee override. Sender, amount, exact input or output, and hook data make no difference.
- Accepts only pools where `currency0` is USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`, `currency1` is STRK `0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766`, and the pool key's fee is the dynamic fee flag. Pool initialization reverts for anything else. Any tick spacing.
- Permissions: after-initialize and before-swap only, no return-delta flags.
- No change path: no owner, setters, storage variables, proxy, `delegatecall`, oracle, external call or token custody. Fees and token addresses are constants. The only constructor argument is the PoolManager (`0x000000000004444c5dc75cB358380D2e3dE08A90` on mainnet).
- Built on OpenZeppelin Uniswap Hooks v1.1.0 `BaseOverrideFee`. OpenZeppelin's audits cover that library, not this hook.

## Build and test

Needs [Foundry](https://getfoundry.sh) 1.8.7 (other versions should compile the same bytecode, but 1.8.7 is what was used).

```sh
git clone --recurse-submodules https://github.com/LesserFoolCrypto/uniswap-v4-hooks
cd uniswap-v4-hooks
forge build
forge test
```

The tests deploy Uniswap's PoolManager and PositionManager locally. No fork and no RPC endpoint are needed.

To check the build against the reviewed one:

```sh
jq -r .deployedBytecode.object out/AccumulationHook.sol/AccumulationHook.json | sha256sum
# 1f795972d46d66fdd6d9862bd09976711701dc415946e3862509be3000d56651
jq -r .bytecode.object out/AccumulationHook.sol/AccumulationHook.json | sha256sum
# 2342e08101433f89a9713da572d74fc1e6007c51284e39945f753c00716974c9
```

The code on chain differs from `deployedBytecode` only where the PoolManager address is stored (an immutable, filled in at deployment).

## Pinned dependencies

Git submodules in `lib/`. The folder names and commits are part of what the bytecode commits to, so don't rename or bump them.

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
