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
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {AccumulationHook} from "../../src/AccumulationHook.sol";

/**
 * @notice Shared setup for the Strategy 08 hook tests (W4, commission S08-M1-015).
 *
 * Everything is local: a v4-core `PoolManager` deployed in the test; solmate `MockERC20` code placed at the canonical
 * USDC and STRK addresses with the real decimals (6 and 18); Permit2 placed at its canonical address from the
 * bytecode the Permit2 repository publishes; a v4-periphery `PositionManager` for liquidity; and v4-core's
 * `PoolSwapTest` router for swaps. No fork, no RPC.
 *
 * Pools: `hookedKey` is the Strategy 08 pool (USDC/STRK, dynamic fee flag, this hook). The three control pools have
 * the same pair, tick spacing, starting price and liquidity but a static fee and no hook: 3%, 1% and 0%. A swap on
 * the hooked pool must give exactly the amounts of the same swap on the static pool at the matching fee.
 */
abstract contract AccumulationHookTestBase is Test, DeployPermit2 {
    using PoolIdLibrary for PoolKey;

    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant STRK = 0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766;

    /// @dev After-initialize (bit 12) and before-swap (bit 7): exactly `0x1080` in the low 14 address bits.
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    uint24 internal constant FEE_USDC_TO_STRK = 30_000;
    uint24 internal constant FEE_STRK_TO_USDC = 10_000;

    int24 internal constant TICK_SPACING = 60;
    /// @dev About 7.96 STRK per USDC (1.0001^297120 = 7.96e12 STRK base units per USDC base unit). A multiple of 60.
    int24 internal constant INIT_TICK = 297_120;
    int24 internal constant TICK_LOWER = INIT_TICK - 6_000;
    int24 internal constant TICK_UPPER = INIT_TICK + 6_000;
    /// @dev Each seeded position holds about 1,000,000 USDC and 7,960,000 STRK at the starting price.
    uint256 internal constant LP_USDC = 1_000_000e6;
    uint256 internal constant LP_STRK = 8_000_000e18;

    /// @dev `BaseHook`'s errors. solc does not expose inherited errors through `AccumulationHook`, and importing
    /// `BaseHook` here would compile a second copy of it under another source name, so the selectors are spelled out.
    bytes4 internal constant NOT_POOL_MANAGER = bytes4(keccak256("NotPoolManager()"));
    bytes4 internal constant HOOK_NOT_IMPLEMENTED = bytes4(keccak256("HookNotImplemented()"));

    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager internal manager;
    IAllowanceTransfer internal permit2;
    PositionManager internal posm;
    PoolSwapTest internal swapRouter;
    AccumulationHook internal hook;

    PoolKey internal hookedKey;
    PoolKey internal static3Key;
    PoolKey internal static1Key;
    PoolKey internal zeroFeeKey;

    uint160 internal sqrtPriceInit;
    uint128 internal positionLiquidity;

    address internal v4Owner;
    address internal lp;
    address internal trader;

    /// @dev One swap as the trader saw it (balance changes) and as the pool manager reported it (`Swap` event).
    struct SwapResult {
        int256 usdcDelta;
        int256 strkDelta;
        int128 eventAmount0;
        int128 eventAmount1;
        uint160 sqrtPriceX96;
        uint128 liquidity;
        int24 tick;
        uint24 eventFee;
    }

    function setUp() public virtual {
        v4Owner = makeAddr("v4Owner");
        lp = makeAddr("lp");
        trader = makeAddr("trader");

        manager = new PoolManager(v4Owner);
        _placeToken(USDC, "USDC", 6);
        _placeToken(STRK, "STRK", 18);
        permit2 = IAllowanceTransfer(deployPermit2());
        posm = new PositionManager(manager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0)));
        swapRouter = new PoolSwapTest(manager);
        hook = _deployHook();
        vm.label(address(manager), "PoolManager");
        vm.label(address(permit2), "Permit2");
        vm.label(address(posm), "PositionManager");
        vm.label(address(swapRouter), "PoolSwapTest");
        vm.label(address(hook), "AccumulationHook");

        hookedKey = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG, address(hook));
        static3Key = _key(FEE_USDC_TO_STRK, address(0));
        static1Key = _key(FEE_STRK_TO_USDC, address(0));
        zeroFeeKey = _key(0, address(0));

        sqrtPriceInit = TickMath.getSqrtPriceAtTick(INIT_TICK);
        positionLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceInit,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            LP_USDC,
            LP_STRK
        );

        _fund(lp, 100 * LP_USDC, 100 * LP_STRK);
        _approvePosm(lp);
        _fund(trader, 100 * LP_USDC, 100 * LP_STRK);
        vm.startPrank(trader);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        IERC20(STRK).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Mock ERC-20 runtime code at a canonical address. `decimals` is immutable in solmate's ERC20, so it carries
    /// over; name and symbol live in storage and do not (no test reads them).
    function _placeToken(address at, string memory symbol, uint8 decimals) internal {
        MockERC20 impl = new MockERC20(symbol, symbol, decimals);
        vm.etch(at, address(impl).code);
        vm.label(at, symbol);
    }

    function _hookInitCode() internal view returns (bytes memory) {
        return abi.encodePacked(type(AccumulationHook).creationCode, abi.encode(address(manager)));
    }

    /// @dev First CREATE2 salt, from `start`, whose address from this contract has exactly `flags` in its low 14
    /// bits and no code yet.
    function _mineSalt(uint160 flags, uint256 start) internal view returns (bytes32 salt, address predicted) {
        bytes32 initCodeHash = keccak256(_hookInitCode());
        for (uint256 i = start; i < start + 1_000_000; ++i) {
            predicted = _create2Address(bytes32(i), initCodeHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) {
                return (bytes32(i), predicted);
            }
        }
        revert("no salt found");
    }

    /// @dev The address `new AccumulationHook{salt: salt}` gets when this contract deploys it:
    /// keccak256(0xff ++ deployer ++ salt ++ initCodeHash). Hashed in scratch memory past the free memory pointer, so
    /// mining loops do not grow memory.
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

    function _deployHook() internal returns (AccumulationHook deployed) {
        (bytes32 salt, address predicted) = _mineSalt(HOOK_FLAGS, 0);
        deployed = new AccumulationHook{salt: salt}(manager);
        assertEq(address(deployed), predicted, "hook address");
        assertEq(uint160(address(deployed)) & Hooks.ALL_HOOK_MASK, 0x1080, "hook address bits");
    }

    function _key(uint24 fee, address hooks) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(STRK),
            fee: fee,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hooks)
        });
    }

    function _fund(address who, uint256 usdc, uint256 strk) internal {
        MockERC20(USDC).mint(who, usdc);
        MockERC20(STRK).mint(who, strk);
    }

    function _approvePosm(address owner) internal {
        vm.startPrank(owner);
        IERC20(USDC).approve(address(permit2), type(uint256).max);
        IERC20(STRK).approve(address(permit2), type(uint256).max);
        permit2.approve(USDC, address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(STRK, address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// @dev Initialize at the starting price and add the standard position from `lp`.
    function _initAndSeed(PoolKey memory key) internal returns (uint256 tokenId) {
        manager.initialize(key, sqrtPriceInit);
        (tokenId,,) = _mint(lp, key, TICK_LOWER, TICK_UPPER, positionLiquidity);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Liquidity through the PositionManager
    // ---------------------------------------------------------------------------------------------------------------

    function _mint(address owner, PoolKey memory key, int24 lower, int24 upper, uint256 liquidity)
        internal
        returns (uint256 tokenId, uint256 paidUsdc, uint256 paidStrk)
    {
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        (int256 dUsdc, int256 dStrk) = _modify(owner, actions, params);
        paidUsdc = uint256(-dUsdc);
        paidStrk = uint256(-dStrk);
    }

    function _increase(address owner, uint256 tokenId, uint256 liquidity)
        internal
        returns (int256 usdcDelta, int256 strkDelta)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.CLOSE_CURRENCY), uint8(Actions.CLOSE_CURRENCY)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(tokenId, liquidity, type(uint128).max, type(uint128).max, bytes(""));
        params[1] = abi.encode(Currency.wrap(USDC));
        params[2] = abi.encode(Currency.wrap(STRK));
        return _modify(owner, actions, params);
    }

    /// @dev Decrease by `liquidity` (0 collects fees only) and take both tokens to the owner.
    function _decrease(address owner, uint256 tokenId, uint256 liquidity)
        internal
        returns (uint256 gotUsdc, uint256 gotStrk)
    {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(USDC), Currency.wrap(STRK), owner);
        (int256 dUsdc, int256 dStrk) = _modify(owner, actions, params);
        gotUsdc = uint256(dUsdc);
        gotStrk = uint256(dStrk);
    }

    function _collect(address owner, uint256 tokenId) internal returns (uint256 gotUsdc, uint256 gotStrk) {
        return _decrease(owner, tokenId, 0);
    }

    /// @dev Full removal: burn the position (removes all liquidity, collects fees) and take both tokens.
    function _burn(address owner, uint256 tokenId) internal returns (uint256 gotUsdc, uint256 gotStrk) {
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(Currency.wrap(USDC), Currency.wrap(STRK), owner);
        (int256 dUsdc, int256 dStrk) = _modify(owner, actions, params);
        gotUsdc = uint256(dUsdc);
        gotStrk = uint256(dStrk);
    }

    function _modify(address owner, bytes memory actions, bytes[] memory params)
        internal
        returns (int256 usdcDelta, int256 strkDelta)
    {
        (uint256 u0, uint256 s0) = _balances(owner);
        vm.prank(owner);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp);
        (uint256 u1, uint256 s1) = _balances(owner);
        usdcDelta = int256(u1) - int256(u0);
        strkDelta = int256(s1) - int256(s0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Swaps through PoolSwapTest
    // ---------------------------------------------------------------------------------------------------------------

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
    }

    /// @dev `amountSpecified` < 0 is exact input, > 0 exact output (v4's convention). Reads the trader's balance
    /// changes and the pool manager's one `Swap` event for this pool.
    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 limit, bytes memory hookData)
        internal
        returns (SwapResult memory r)
    {
        (uint256 u0, uint256 s0) = _balances(trader);
        vm.recordLogs();
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        _readSwapEvent(vm.getRecordedLogs(), key.toId(), r);
        (uint256 u1, uint256 s1) = _balances(trader);
        r.usdcDelta = int256(u1) - int256(u0);
        r.strkDelta = int256(s1) - int256(s0);
        // The trader's balance changes are exactly the pool manager's swap delta.
        assertEq(r.usdcDelta, r.eventAmount0, "USDC balance change = event amount0");
        assertEq(r.strkDelta, r.eventAmount1, "STRK balance change = event amount1");
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
        assertEq(a.usdcDelta, b.usdcDelta, "USDC delta");
        assertEq(a.strkDelta, b.strkDelta, "STRK delta");
        assertEq(a.eventAmount0, b.eventAmount0, "event amount0");
        assertEq(a.eventAmount1, b.eventAmount1, "event amount1");
        assertEq(a.sqrtPriceX96, b.sqrtPriceX96, "price after");
        assertEq(a.liquidity, b.liquidity, "liquidity after");
        assertEq(a.tick, b.tick, "tick after");
        assertEq(a.eventFee, b.eventFee, "event fee");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Misc
    // ---------------------------------------------------------------------------------------------------------------

    function _balances(address who) internal view returns (uint256 usdc, uint256 strk) {
        usdc = IERC20(USDC).balanceOf(who);
        strk = IERC20(STRK).balanceOf(who);
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(IERC20(USDC).balanceOf(address(hook)), 0, "hook USDC");
        assertEq(IERC20(STRK).balanceOf(address(hook)), 0, "hook STRK");
        assertEq(address(hook).balance, 0, "hook ETH");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(USDC))), 0, "hook USDC claims");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(STRK))), 0, "hook STRK claims");
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
