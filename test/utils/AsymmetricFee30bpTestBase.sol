// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {PositionInfo} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {AsymmetricFeeBase} from "../../src/AsymmetricFeeBase.sol";
import {AsymmetricFee_30bp_100bp} from "../../src/AsymmetricFee_30bp_100bp.sol";
import {AsymmetricFee_100bp_30bp} from "../../src/AsymmetricFee_100bp_30bp.sol";

/// @notice Which hook a test contract runs against. Kept apart from `AsymmetricFee30bpTestBase` so a test file can
/// override `setUp` and still be mixed with either hook without restating the override in every concrete contract.
abstract contract AsymmetricFee30bpHookUnderTest {
    function _hookCreationCode() internal pure virtual returns (bytes memory);

    function _newHook(bytes32 salt) internal virtual returns (AsymmetricFeeBase);

    /// @dev The fee the README table gives when token0 is paid in.
    function _token0InFee() internal pure virtual returns (uint24);

    /// @dev The fee the README table gives when token1 is paid in.
    function _token1InFee() internal pure virtual returns (uint24);
}

/**
 * @notice Shared setup for the tests of the 0.3%/1% Asymmetric Fee hooks, `AsymmetricFee_30bp_100bp` and
 * `AsymmetricFee_100bp_30bp`. Self-contained: it imports no other test file, so these tests can be published on their
 * own.
 *
 * Everything is local: no fork, no RPC. A v4-core `PoolManager` sits at Ethereum mainnet's PoolManager address, the
 * only caller the hooks answer (`_deployAt`: its creation code runs at that address, so its no-delegate-call check
 * and its owner belong to that address). Three solmate `MockERC20` tokens (18 decimals) sit at fixed addresses that
 * sort LOW < MID < HIGH, so MID is token1 against LOW and token0 against HIGH; native ETH (address zero) is always
 * token0. Permit2 at its canonical address from the bytecode the Permit2 repository publishes; a v4-periphery
 * `PositionManager` for liquidity (no WETH9); v4-core's `PoolSwapTest` router for swaps.
 *
 * Pairs: 0 = ETH/MID (about 998 MID per ETH), 1 = LOW/MID and 2 = MID/HIGH (both 1:1). Each pair has a hooked pool
 * (dynamic fee flag, the hook under test) and two control pools with the same pair, tick spacing, starting price and
 * position but a static fee of 0.3% or 1% and no hook. A swap on the hooked pool must give exactly the amounts of the
 * same swap on the control pool at the fee the hook should charge.
 *
 * Each test contract runs against one hook, chosen by mixing in `UsesHook_30bp_100bp` or `UsesHook_100bp_30bp`
 * (bottom of this file); every test file declares one concrete contract per hook. The expected fees come from the
 * mixin, written out from the README table, not read from the hook.
 *
 * ETH accounting: the gas price is set to zero, and every swap and liquidity call checks that the caller's balance
 * change in each currency is exactly the opposite of the pool manager's, that the swap router and the
 * `PositionManager` hold exactly zero ETH afterwards, and that the hook holds no ETH, tokens or claims.
 */
abstract contract AsymmetricFee30bpTestBase is Test, DeployPermit2, AsymmetricFee30bpHookUnderTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal constant MAINNET_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;

    address internal constant TOKEN_LOW = 0x1111111111111111111111111111111111111111;
    address internal constant TOKEN_MID = 0x5555555555555555555555555555555555555555;
    address internal constant TOKEN_HIGH = 0x9999999999999999999999999999999999999999;
    Currency internal constant ETH = Currency.wrap(address(0));

    uint256 internal constant ETH_MID = 0;
    uint256 internal constant LOW_MID = 1;
    uint256 internal constant MID_HIGH = 2;
    uint256 internal constant PAIR_COUNT = 3;

    /// @dev After-initialize (bit 12) and before-swap (bit 7): exactly `0x1080` in the low 14 address bits.
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    /// @dev The static fees of the control pools: the two fees these hooks charge.
    uint24 internal constant FEE_0_3PCT = 3_000;
    uint24 internal constant FEE_1PCT = 10_000;

    int24 internal constant TICK_SPACING = 60;
    /// @dev 1.0001^69060 = about 998 MID per ETH. A multiple of 60.
    int24 internal constant ETH_MID_TICK = 69_060;
    int24 internal constant HALF_RANGE = 6_000;

    /// @dev ETH sent beyond what a liquidity add needs, to show the unused part comes back in the same call.
    uint256 internal constant ETH_EXTRA = 1 ether;
    /// @dev ETH sent with an exact-output ETH-in swap; the router returns what the pool does not take.
    uint256 internal constant ETH_FOR_EXACT_OUTPUT = 100_000 ether;

    /// @dev `BaseHook`'s errors. solc does not expose inherited errors through the hook contracts, and importing
    /// `BaseHook` here would compile a second copy of it under another source name, so the selectors are spelled out.
    bytes4 internal constant NOT_POOL_MANAGER = bytes4(keccak256("NotPoolManager()"));
    bytes4 internal constant HOOK_NOT_IMPLEMENTED = bytes4(keccak256("HookNotImplemented()"));

    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager internal manager;
    IAllowanceTransfer internal permit2;
    PositionManager internal posm;
    PoolSwapTest internal swapRouter;
    AsymmetricFeeBase internal hook;

    address internal v4Owner;
    address internal lp;
    address internal trader;

    struct Pair {
        Currency currency0;
        Currency currency1;
        int24 initTick;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    Pair[PAIR_COUNT] internal pairs;

    /// @dev One swap as the trader saw it (balance changes) and as the pool manager reported it (`Swap` event).
    struct SwapResult {
        int256 delta0;
        int256 delta1;
        int128 eventAmount0;
        int128 eventAmount1;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
        uint24 eventFee;
    }

    struct Balances {
        uint256 owner0;
        uint256 owner1;
        uint256 manager0;
        uint256 manager1;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The hook under test (`AsymmetricFee30bpHookUnderTest`, set by the mixins at the bottom of this file)
    // ---------------------------------------------------------------------------------------------------------------

    function _feeFor(bool zeroForOne) internal pure returns (uint24) {
        return zeroForOne ? _token0InFee() : _token1InFee();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Setup
    // ---------------------------------------------------------------------------------------------------------------

    function setUp() public virtual {
        vm.txGasPrice(0);
        v4Owner = makeAddr("v4Owner");
        lp = makeAddr("lp");
        trader = makeAddr("trader");

        manager = _placePoolManager(v4Owner);
        _deployAt(TOKEN_LOW, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Low", "LOW", uint8(18))));
        _deployAt(TOKEN_MID, abi.encodePacked(type(MockERC20).creationCode, abi.encode("Mid", "MID", uint8(18))));
        _deployAt(TOKEN_HIGH, abi.encodePacked(type(MockERC20).creationCode, abi.encode("High", "HIGH", uint8(18))));
        permit2 = IAllowanceTransfer(deployPermit2());
        posm = new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        swapRouter = new PoolSwapTest(manager);
        hook = _deployHook();
        vm.label(address(manager), "PoolManager");
        vm.label(TOKEN_LOW, "LOW");
        vm.label(TOKEN_MID, "MID");
        vm.label(TOKEN_HIGH, "HIGH");
        vm.label(address(permit2), "Permit2");
        vm.label(address(posm), "PositionManager");
        vm.label(address(swapRouter), "PoolSwapTest");
        vm.label(address(hook), "hook");

        _setPair(ETH_MID, ETH, Currency.wrap(TOKEN_MID), ETH_MID_TICK, 1_000 ether, 1_000_000e18);
        _setPair(LOW_MID, Currency.wrap(TOKEN_LOW), Currency.wrap(TOKEN_MID), 0, 1_000_000e18, 1_000_000e18);
        _setPair(MID_HIGH, Currency.wrap(TOKEN_MID), Currency.wrap(TOKEN_HIGH), 0, 1_000_000e18, 1_000_000e18);

        _fund(lp);
        _fund(trader);
    }

    /// @dev Runs `initCode` (creation code with its constructor arguments appended) as the code at `at`, so the
    /// constructor runs with `address(this) == at`: immutables such as v4's no-delegate-call address are computed for
    /// `at`, and storage the constructor writes (the owner) lands at `at`. Then places the runtime code it returns.
    /// Not forge-std's `deployCodeTo`, which reads compiled artifacts from disk (`fs_permissions = []` denies that).
    function _deployAt(address at, bytes memory initCode) internal {
        vm.etch(at, initCode);
        (bool ok, bytes memory runtime) = at.call("");
        require(ok, "constructor reverted");
        vm.etch(at, runtime);
    }

    function _placePoolManager(address owner) internal returns (IPoolManager) {
        _deployAt(MAINNET_POOL_MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(owner)));
        return IPoolManager(MAINNET_POOL_MANAGER);
    }

    /// @dev First CREATE2 salt, from `start`, whose address from this contract has exactly `flags` in its low 14
    /// bits and no code yet.
    function _mineSalt(bytes memory initCode, uint160 flags, uint256 start)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = start; i < start + 1_000_000; ++i) {
            predicted = _create2Address(bytes32(i), initCodeHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) {
                return (bytes32(i), predicted);
            }
        }
        revert("no salt found");
    }

    /// @dev The address a CREATE2 from this contract gets: keccak256(0xff ++ deployer ++ salt ++ initCodeHash). Hashed
    /// in scratch memory past the free memory pointer, so mining loops do not grow memory.
    function _create2Address(bytes32 salt, bytes32 initCodeHash) internal view returns (address predicted) {
        address deployer = address(this);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(add(ptr, 0x40), initCodeHash)
            mstore(add(ptr, 0x20), salt)
            mstore(ptr, deployer)
            mstore8(add(ptr, 0x0b), 0xff)
            predicted := and(keccak256(add(ptr, 0x0b), 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _deployHook() internal returns (AsymmetricFeeBase deployed) {
        (bytes32 salt, address predicted) = _mineSalt(_hookCreationCode(), HOOK_FLAGS, 0);
        deployed = _newHook(salt);
        assertEq(address(deployed), predicted, "hook address");
        assertEq(uint160(address(deployed)) & Hooks.ALL_HOOK_MASK, 0x1080, "hook address bits");
    }

    function _setPair(uint256 p, Currency c0, Currency c1, int24 initTick, uint256 amount0, uint256 amount1) internal {
        Pair storage pair = pairs[p];
        pair.currency0 = c0;
        pair.currency1 = c1;
        pair.initTick = initTick;
        pair.tickLower = initTick - HALF_RANGE;
        pair.tickUpper = initTick + HALF_RANGE;
        pair.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            TickMath.getSqrtPriceAtTick(initTick),
            TickMath.getSqrtPriceAtTick(pair.tickLower),
            TickMath.getSqrtPriceAtTick(pair.tickUpper),
            amount0,
            amount1
        );
    }

    function _fund(address who) internal {
        vm.deal(who, 10_000_000 ether);
        address[3] memory tokens = [TOKEN_LOW, TOKEN_MID, TOKEN_HIGH];
        vm.startPrank(who);
        for (uint256 i; i < tokens.length; ++i) {
            MockERC20(tokens[i]).mint(who, 1e30);
            IERC20(tokens[i]).approve(address(swapRouter), type(uint256).max);
            IERC20(tokens[i]).approve(address(permit2), type(uint256).max);
            permit2.approve(tokens[i], address(posm), type(uint160).max, type(uint48).max);
        }
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Pools
    // ---------------------------------------------------------------------------------------------------------------

    function _key(uint256 p, uint24 fee, address hooks) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: pairs[p].currency0,
            currency1: pairs[p].currency1,
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
        });
    }

    function _hookedKey(uint256 p) internal view returns (PoolKey memory) {
        return _key(p, LPFeeLibrary.DYNAMIC_FEE_FLAG, address(hook));
    }

    function _staticKey(uint256 p, uint24 fee) internal view returns (PoolKey memory) {
        return _key(p, fee, address(0));
    }

    /// @dev The control pool for a swap direction: the static pool at the fee the hook should charge.
    function _controlKey(uint256 p, bool zeroForOne) internal view returns (PoolKey memory) {
        return _staticKey(p, _feeFor(zeroForOne));
    }

    function _sqrtInit(uint256 p) internal view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(pairs[p].initTick);
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = manager.getSlot0(key.toId());
    }

    /// @dev Initialize at the pair's starting price and add the pair's standard position from `lp`.
    function _initAndSeed(uint256 p, PoolKey memory key) internal returns (uint256 tokenId) {
        manager.initialize(key, _sqrtInit(p));
        (tokenId,,) = _mint(lp, key, pairs[p].tickLower, pairs[p].tickUpper, pairs[p].liquidity);
    }

    /// @dev The hooked pool and both control pools of pair `p`.
    function _initAndSeedPair(uint256 p) internal returns (uint256 hookedTokenId) {
        hookedTokenId = _initAndSeed(p, _hookedKey(p));
        _initAndSeed(p, _staticKey(p, FEE_0_3PCT));
        _initAndSeed(p, _staticKey(p, FEE_1PCT));
    }

    function _initAndSeedAllPairs() internal {
        for (uint256 p; p < PAIR_COUNT; ++p) {
            _initAndSeedPair(p);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidity through the PositionManager
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Mint, then settle both currencies. With native ETH: ETH_EXTRA more than needed is sent as value and the
    /// unused part swept back to the owner in the same call. The owner's payment is checked to the wei against v4's
    /// own amount math.
    function _mint(address owner, PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        internal
        returns (uint256 tokenId, int256 delta0, int256 delta1)
    {
        (int256 e0, int256 e1) = _principal(key, lower, upper, int128(liquidity));
        tokenId = posm.nextTokenId();
        (bytes memory actions, bytes[] memory params) = _mintActions(owner, key, lower, upper, liquidity);
        uint256 value = key.currency0.isAddressZero() ? uint256(-e0) + ETH_EXTRA : 0;
        (delta0, delta1) = _modify(owner, key, actions, params, value);
        assertEq(delta0, e0, "mint: currency0 paid, to the wei");
        assertEq(delta1, e1, "mint: currency1 paid, to the wei");
        assertEq(posm.ownerOf(tokenId), owner);
    }

    /// @dev `MINT_POSITION`, `SETTLE_PAIR`, and with native ETH a `SWEEP` of the unused ETH to the owner.
    function _mintActions(address owner, PoolKey memory key, int24 lower, int24 upper, uint128 liquidity)
        internal
        pure
        returns (bytes memory actions, bytes[] memory params)
    {
        bool native = key.currency0.isAddressZero();
        actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        params = new bytes[](native ? 3 : 2);
        params[0] =
            abi.encode(key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        if (native) {
            actions = abi.encodePacked(actions, uint8(Actions.SWEEP));
            params[2] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, owner);
        }
    }

    /// @dev Increase with the close-or-settle-then-sweep pattern: `CLOSE_CURRENCY` for each currency settles what is
    /// owed or takes what is due (fees already earned can exceed what the increase needs, where `SETTLE_PAIR` would
    /// revert), then with native ETH a `SWEEP` returns the ETH sent beyond what was settled.
    function _increase(address owner, uint256 tokenId, uint128 liquidity)
        internal
        returns (int256 delta0, int256 delta1)
    {
        (PoolKey memory key, int256 e0, int256 e1) = _expectedChange(tokenId, int128(liquidity));
        bool native = key.currency0.isAddressZero();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](native ? 4 : 3);
        params[0] = abi.encode(tokenId, uint256(liquidity), type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(key.currency0);
        params[2] = abi.encode(key.currency1);
        uint256 value;
        if (native) {
            actions = abi.encodePacked(actions, uint8(Actions.SWEEP));
            params[3] = abi.encode(CurrencyLibrary.ADDRESS_ZERO, owner);
            value = (e0 < 0 ? uint256(-e0) : 0) + ETH_EXTRA;
        }
        (delta0, delta1) = _modify(owner, key, actions, params, value);
        assertEq(delta0, e0, "increase: currency0 change (fees less principal), to the wei");
        assertEq(delta1, e1, "increase: currency1 change (fees less principal), to the wei");
    }

    /// @dev Decrease by `liquidity` (0 collects fees only) and take both currencies to the owner. Native ETH arrives
    /// as plain ETH straight from the pool manager.
    function _decrease(address owner, uint256 tokenId, uint128 liquidity)
        internal
        returns (uint256 got0, uint256 got1)
    {
        (PoolKey memory key, int256 e0, int256 e1) = _expectedChange(tokenId, -int128(liquidity));
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, owner);
        (int256 d0, int256 d1) = _modify(owner, key, actions, params, 0);
        assertEq(d0, e0, "decrease: currency0 received, to the wei");
        assertEq(d1, e1, "decrease: currency1 received, to the wei");
        got0 = uint256(d0);
        got1 = uint256(d1);
    }

    function _collect(address owner, uint256 tokenId) internal returns (uint256 got0, uint256 got1) {
        return _decrease(owner, tokenId, 0);
    }

    /// @dev Full removal: burn the position (removes all liquidity, collects fees) and take both currencies.
    function _burn(address owner, uint256 tokenId) internal returns (uint256 got0, uint256 got1) {
        uint128 liquidity = posm.getPositionLiquidity(tokenId);
        (PoolKey memory key, int256 e0, int256 e1) = _expectedChange(tokenId, -int128(liquidity));
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, owner);
        (int256 d0, int256 d1) = _modify(owner, key, actions, params, 0);
        assertEq(d0, e0, "burn: currency0 received, to the wei");
        assertEq(d1, e1, "burn: currency1 received, to the wei");
        got0 = uint256(d0);
        got1 = uint256(d1);
        vm.expectRevert(bytes("NOT_MINTED"));
        posm.ownerOf(tokenId);
    }

    /// @dev Calls the PositionManager as `owner` with `value` and returns the owner's balance changes. Checks the
    /// pool manager's balances moved by exactly the opposite amounts (nothing went anywhere else), and that the
    /// PositionManager and the swap router hold exactly zero ETH afterwards.
    function _modify(address owner, PoolKey memory key, bytes memory actions, bytes[] memory params, uint256 value)
        internal
        returns (int256 delta0, int256 delta1)
    {
        Balances memory b = _balancesOf(key, owner);
        vm.prank(owner);
        posm.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
        Balances memory a = _balancesOf(key, owner);
        delta0 = int256(a.owner0) - int256(b.owner0);
        delta1 = int256(a.owner1) - int256(b.owner1);
        assertEq(int256(a.manager0) - int256(b.manager0), -delta0, "pool manager currency0 change");
        assertEq(int256(a.manager1) - int256(b.manager1), -delta1, "pool manager currency1 change");
        assertEq(address(posm).balance, 0, "PositionManager holds no ETH");
        assertEq(address(swapRouter).balance, 0, "swap router holds no ETH");
        _assertHookHoldsNothing();
    }

    /// @dev What a liquidity change of `liquidityDelta` on `tokenId` pays the owner (positive) or costs (negative),
    /// in each currency: the principal from v4's amount math at the current price, plus the fees the position has
    /// earned (v4 credits them on any liquidity change).
    function _expectedChange(uint256 tokenId, int128 liquidityDelta)
        internal
        view
        returns (PoolKey memory key, int256 e0, int256 e1)
    {
        PositionInfo info;
        (key, info) = posm.getPoolAndPositionInfo(tokenId);
        (e0, e1) = _principal(key, info.tickLower(), info.tickUpper(), liquidityDelta);
        (uint256 f0, uint256 f1) = _feesOwed(key, tokenId);
        e0 += int256(f0);
        e1 += int256(f1);
    }

    /// @dev The caller's currency deltas for a liquidity change, as `Pool.modifyLiquidity` computes them.
    function _principal(PoolKey memory key, int24 lower, int24 upper, int128 liquidityDelta)
        internal
        view
        returns (int256 d0, int256 d1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = manager.getSlot0(key.toId());
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        if (tick < lower) {
            d0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidityDelta);
        } else if (tick < upper) {
            d0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidityDelta);
            d1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidityDelta);
        } else {
            d1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidityDelta);
        }
    }

    /// @dev Fees a PositionManager position has earned and not yet collected, as `Position.update` computes them.
    function _feesOwed(PoolKey memory key, uint256 tokenId) internal view returns (uint256 f0, uint256 f1) {
        (, PositionInfo info) = posm.getPoolAndPositionInfo(tokenId);
        (uint128 liquidity, uint256 last0, uint256 last1) =
            manager.getPositionInfo(key.toId(), address(posm), info.tickLower(), info.tickUpper(), bytes32(tokenId));
        (uint256 inside0, uint256 inside1) = manager.getFeeGrowthInside(key.toId(), info.tickLower(), info.tickUpper());
        unchecked {
            f0 = FullMath.mulDiv(inside0 - last0, liquidity, FixedPoint128.Q128);
            f1 = FullMath.mulDiv(inside1 - last1, liquidity, FixedPoint128.Q128);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps through PoolSwapTest
    // ---------------------------------------------------------------------------------------------------------------

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    /// @dev ETH sent with a swap: with ETH in, exactly the input for exact input, or a surplus for exact output (the
    /// router returns what the pool does not take). Nothing otherwise.
    function _swapValue(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal pure returns (uint256) {
        if (!key.currency0.isAddressZero() || !zeroForOne) return 0;
        return amountSpecified < 0 ? uint256(-amountSpecified) : ETH_FOR_EXACT_OUTPUT;
    }

    /// @dev `amountSpecified` < 0 is exact input, > 0 exact output (v4's convention). Reads the trader's balance
    /// changes and the pool manager's one `Swap` event for this pool, and checks they agree to the wei.
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes memory hookData)
        internal
        returns (SwapResult memory r)
    {
        Balances memory b = _balancesOf(key, trader);
        uint256 value = _swapValue(key, zeroForOne, amountSpecified);
        vm.recordLogs();
        vm.prank(trader);
        swapRouter.swap{value: value}(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        _readSwapEvent(vm.getRecordedLogs(), key.toId(), r);
        Balances memory a = _balancesOf(key, trader);
        r.delta0 = int256(a.owner0) - int256(b.owner0);
        r.delta1 = int256(a.owner1) - int256(b.owner1);
        assertEq(r.delta0, r.eventAmount0, "trader currency0 change = event amount0");
        assertEq(r.delta1, r.eventAmount1, "trader currency1 change = event amount1");
        assertEq(int256(a.manager0) - int256(b.manager0), -r.delta0, "pool manager currency0 change");
        assertEq(int256(a.manager1) - int256(b.manager1), -r.delta1, "pool manager currency1 change");
        assertEq(address(swapRouter).balance, 0, "swap router holds no ETH");
        _assertHookHoldsNothing();
    }

    function _readSwapEvent(Vm.Log[] memory logs, PoolId id, SwapResult memory r) internal view {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (
                log.emitter == address(manager) && log.topics[0] == IPoolManager.Swap.selector
                    && log.topics[1] == PoolId.unwrap(id)
            ) {
                (r.eventAmount0, r.eventAmount1, r.sqrtPriceX96, r.liquidity, r.tick, r.eventFee) =
                    abi.decode(log.data, (int128, int128, uint160, uint128, int24, uint24));
                ++found;
            }
        }
        assertEq(found, 1, "one Swap event");
    }

    function _assertSameSwap(SwapResult memory a, SwapResult memory b) internal pure {
        assertEq(a.delta0, b.delta0, "currency0 delta");
        assertEq(a.delta1, b.delta1, "currency1 delta");
        assertEq(a.eventAmount0, b.eventAmount0, "event amount0");
        assertEq(a.eventAmount1, b.eventAmount1, "event amount1");
        assertEq(a.sqrtPriceX96, b.sqrtPriceX96, "price after");
        assertEq(a.liquidity, b.liquidity, "liquidity after");
        assertEq(a.tick, b.tick, "tick after");
        assertEq(a.eventFee, b.eventFee, "event fee");
    }

    /// @dev The same swap on the hooked pool of pair `p` and on its control pool, each from the current state (both
    /// pools must be in the same state): identical amounts, price, liquidity, tick and event fee, and the event fee
    /// is the one the hook should charge. Leaves the state as it was.
    function _matchControl(uint256 p, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (SwapResult memory h)
    {
        uint256 snap = vm.snapshotState();
        h = _swap(_hookedKey(p), zeroForOne, amountSpecified, _limit(zeroForOne), hookData);
        vm.revertToState(snap);
        SwapResult memory c = _swap(_controlKey(p, zeroForOne), zeroForOne, amountSpecified, _limit(zeroForOne), "");
        vm.revertToState(snap);
        _assertSameSwap(h, c);
        assertEq(h.eventFee, _feeFor(zeroForOne), "event fee = the hook's fee for this direction");
    }

    /// @dev Swaps each control pool of pair `p` to the hooked pool's current price (an exact-output swap far larger
    /// than the pool, stopped by the price limit). The pools hold the same position over the same range, so at the
    /// same price they hold the same liquidity and give the same amounts for any swap (fees earned by the LP sit
    /// apart from the price curve).
    function _alignControlsWithHooked(uint256 p) internal {
        uint160 target = _sqrtPrice(_hookedKey(p));
        uint24[2] memory fees = [FEE_0_3PCT, FEE_1PCT];
        for (uint256 i; i < fees.length; ++i) {
            uint160 current = _sqrtPrice(_staticKey(p, fees[i]));
            if (current == target) continue;
            _swap(_staticKey(p, fees[i]), target < current, int256(1e30), target, "");
            assertEq(_sqrtPrice(_staticKey(p, fees[i])), target, "control at the hooked pool's price");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Misc
    // ---------------------------------------------------------------------------------------------------------------

    function _balanceOf(Currency currency, address who) internal view returns (uint256) {
        return currency.isAddressZero() ? who.balance : IERC20(Currency.unwrap(currency)).balanceOf(who);
    }

    function _balancesOf(PoolKey memory key, address owner) internal view returns (Balances memory b) {
        b.owner0 = _balanceOf(key.currency0, owner);
        b.owner1 = _balanceOf(key.currency1, owner);
        b.manager0 = _balanceOf(key.currency0, address(manager));
        b.manager1 = _balanceOf(key.currency1, address(manager));
    }

    /// @dev No ETH, no tokens and no pool manager claims (ERC-6909) of any currency in these tests.
    function _assertHookHoldsNothing() internal view {
        _assertHoldsNothing(address(hook));
    }

    function _assertHoldsNothing(address who) internal view {
        assertEq(who.balance, 0, "hook ETH");
        address[4] memory currencies = [address(0), TOKEN_LOW, TOKEN_MID, TOKEN_HIGH];
        for (uint256 i; i < currencies.length; ++i) {
            if (currencies[i] != address(0)) assertEq(IERC20(currencies[i]).balanceOf(who), 0, "hook token");
            assertEq(manager.balanceOf(who, uint256(uint160(currencies[i]))), 0, "hook claims");
        }
    }

    /// @dev A hook revert as the pool manager reports it: `WrappedError(hook, hookFunction, reason, HookCallFailed)`.
    function _wrappedHookError(bytes4 hookFunction, bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            hookFunction,
            reason,
            abi.encodePacked(Hooks.HookCallFailed.selector)
        );
    }
}

/// @notice Runs a test contract against `AsymmetricFee_30bp_100bp`: 0.3% when token0 is paid in, 1% when token1 is.
abstract contract UsesHook_30bp_100bp is AsymmetricFee30bpHookUnderTest {
    function _hookCreationCode() internal pure override returns (bytes memory) {
        return type(AsymmetricFee_30bp_100bp).creationCode;
    }

    function _newHook(bytes32 salt) internal override returns (AsymmetricFeeBase) {
        return new AsymmetricFee_30bp_100bp{salt: salt}();
    }

    function _token0InFee() internal pure override returns (uint24) {
        return 3_000;
    }

    function _token1InFee() internal pure override returns (uint24) {
        return 10_000;
    }
}

/// @notice Runs a test contract against `AsymmetricFee_100bp_30bp`: 1% when token0 is paid in, 0.3% when token1 is.
abstract contract UsesHook_100bp_30bp is AsymmetricFee30bpHookUnderTest {
    function _hookCreationCode() internal pure override returns (bytes memory) {
        return type(AsymmetricFee_100bp_30bp).creationCode;
    }

    function _newHook(bytes32 salt) internal override returns (AsymmetricFeeBase) {
        return new AsymmetricFee_100bp_30bp{salt: salt}();
    }

    function _token0InFee() internal pure override returns (uint24) {
        return 10_000;
    }

    function _token1InFee() internal pure override returns (uint24) {
        return 3_000;
    }
}
