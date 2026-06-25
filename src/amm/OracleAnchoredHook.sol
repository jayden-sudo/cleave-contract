// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseTestHooks} from "@uniswap/v4-core/src/test/BaseTestHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CleaveQuoteMath} from "./CleaveQuoteMath.sol";

interface IFastOracle {
    function price() external view returns (uint256); // USD per 1 unit, 1e18-scaled
}

/// @title OracleAnchoredHook
/// @notice Uniswap v4 custom-curve hook for Cleave's P/USDC venue. Instead of a passive
///         constant-product curve, it quotes the cash leg P at a guide price `i` streamed by a
///         keeper, plus/minus a thin spread `fee`, against its own P/USDC inventory (the proPAMM
///         principle; see ORACLE_AMM_DESIGN.md). Only the P leg needs an AMM — N is pinned by
///         split/combine parity. Settlement is unchanged (the slow median oracle); this hook only
///         affects *trading* and never touches the formally-verified Series core.
///
///         Safety: `i` is clamped on-chain to the model-free no-arb band (0, min(spotFast, strike)]
///         using a FAST quote oracle, so a wrong/malicious keeper can't push the price past where
///         arbitrage (split/combine) already bounds it — worst case is bounded arb cost, not a rug.
///         A stale quote (dead keeper) PAUSES swaps (combine() remains the always-available par
///         exit), rather than letting the venue be adversely selected.
///
/// @dev    v1: exact-input only; fee is streamed by the keeper (vol-/staleness-scaled off-chain) and
///         baked into the price, so no v4 dynamic-fee plumbing is needed. CFMM tail + on-chain
///         staleness widening are v2. Inherits BaseTestHooks for the IHooks default reverts.
contract OracleAnchoredHook is BaseTestHooks, IUnlockCallback {
    using CurrencySettler for Currency;
    using SafeCast for uint256;
    using SafeCast for int256;

    IPoolManager public immutable manager;
    IFastOracle public immutable fastOracle;
    Currency public immutable pCurrency; // the P (cash leg) token
    Currency public immutable usdc;
    uint256 public immutable strikeWad; // series strike, USD 1e18
    uint256 public immutable maxFeeWad; // spread cap
    uint256 public immutable maxQuoteAge; // seconds before swaps pause on a stale quote
    address public immutable keeper;
    address public immutable owner; // seeds/reclaims inventory

    uint256 public iWad; // keeper guide price, USD per P, 1e18
    uint256 public feeWad; // keeper spread fraction, 1e18
    uint256 public lastUpdate;

    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_QUOTE_MOVE_WAD = 0.25e18; // max |move| of the guide per keeper update

    error NotKeeper();
    error NotOwner();
    error NotManager();
    error FeeTooHigh();
    error StaleQuote();
    error GuideZero();
    error ExactInputOnly();
    error InsufficientInventory();
    error WrongPool();
    error ZeroOutput();
    error QuoteMoveTooLarge();

    event QuoteUpdated(uint256 iWad, uint256 feeWad, uint256 at);

    constructor(
        IPoolManager _manager,
        IFastOracle _fastOracle,
        Currency _p,
        Currency _usdc,
        uint256 _strikeWad,
        uint256 _maxFeeWad,
        uint256 _maxQuoteAge,
        address _keeper,
        address _owner
    ) {
        manager = _manager;
        fastOracle = _fastOracle;
        pCurrency = _p;
        usdc = _usdc;
        strikeWad = _strikeWad;
        maxFeeWad = _maxFeeWad;
        maxQuoteAge = _maxQuoteAge;
        keeper = _keeper;
        owner = _owner;

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(manager));
        _;
    }

    /// @notice Keeper streams the guide price (USD per P, 1e18) and spread (1e18). The model lives
    ///         off-chain; the hook bounds it on-chain (clamp + maxFee).
    function updateQuote(uint256 _iWad, uint256 _feeWad) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (_iWad == 0) revert GuideZero();
        if (_feeWad > maxFeeWad) revert FeeTooHigh();
        // Bound the per-update move so a single compromised keeper write can't slam the guide to its
        // floor in one tx (the keeper re-quotes incrementally). First quote (iWad==0) is unbounded.
        uint256 prev = iWad;
        if (prev != 0) {
            if (
                _iWad < Math.mulDiv(prev, WAD - MAX_QUOTE_MOVE_WAD, WAD)
                    || _iWad > Math.mulDiv(prev, WAD + MAX_QUOTE_MOVE_WAD, WAD)
            ) revert QuoteMoveTooLarge();
        }
        iWad = _iWad;
        feeWad = _feeWad;
        lastUpdate = block.timestamp;
        emit QuoteUpdated(_iWad, _feeWad, block.timestamp);
    }

    /// @notice Owner deposits `amount` of real `currency` (already transferred to this hook) as the
    ///         maker's ERC-6909 claim inventory. Unlocks the manager, pays the real tokens, mints the
    ///         matching claims to the hook.
    function deposit(Currency currency, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        manager.unlock(abi.encode(currency, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(manager)) revert NotManager();
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        currency.settle(manager, address(this), amount, false); // pay real tokens the owner sent here
        manager.mint(address(this), currency.toId(), amount); // mint the matching claim inventory
        return "";
    }

    /// @notice Owner reclaims seeded inventory. Reserves are held as ERC-6909 claim tokens; this
    ///         transfers the claim to `to`, who redeems it for the underlying via the manager.
    function withdraw(Currency currency, uint256 amount, address to) external {
        if (msg.sender != owner) revert NotOwner();
        manager.transfer(to, currency.toId(), amount);
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // CRITICAL: only the canonical {P, USDC} pair may swap here. Inventory is GLOBAL ERC-6909
        // claims and v4 pool init is permissionless, so without this a rogue pool reusing this hook
        // with an attacker token opposite P or USDC would drain the real inventory in one swap.
        {
            address c0 = Currency.unwrap(key.currency0);
            address c1 = Currency.unwrap(key.currency1);
            address p_ = Currency.unwrap(pCurrency);
            address u_ = Currency.unwrap(usdc);
            if (!((c0 == p_ && c1 == u_) || (c0 == u_ && c1 == p_))) revert WrongPool();
        }
        if (block.timestamp - lastUpdate > maxQuoteAge) revert StaleQuote();
        if (params.amountSpecified >= 0) revert ExactInputOnly();

        uint256 i = CleaveQuoteMath.clampGuide(iWad, fastOracle.price(), strikeWad);
        if (i == 0) revert GuideZero();

        uint256 amountIn = uint256(-params.amountSpecified);
        (Currency input, Currency output) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);

        uint256 amountOut = (Currency.unwrap(input) == Currency.unwrap(pCurrency))
            ? CleaveQuoteMath.usdcOutForP(amountIn, i, feeWad) // sell P -> USDC
            : CleaveQuoteMath.pOutForUsdc(amountIn, i, feeWad); // buy P with USDC
        if (amountOut == 0) revert ZeroOutput(); // dust input must not take() without paying out

        // The hook is the counterparty and holds its reserves as ERC-6909 claim tokens in the manager
        // (so beforeSwap is pure flash-accounting — no real transfer out of the manager, which has no
        // reserves yet at this point in the swap). Receive the input as a minted claim, pay the output
        // by burning a claim from the hook's inventory.
        if (manager.balanceOf(address(this), output.toId()) < amountOut) revert InsufficientInventory();
        input.take(manager, address(this), amountIn, true); // claims=true: mint input claim to the hook
        output.settle(manager, address(this), amountOut, true); // burn=true: burn the hook's output claim

        // Exact-input: specified delta = +amountIn (hook took the input), unspecified = -amountOut
        // (hook owes the output). This fully replaces the pool's own curve.
        BeforeSwapDelta delta = toBeforeSwapDelta(amountIn.toInt256().toInt128(), -amountOut.toInt256().toInt128());
        return (IHooks.beforeSwap.selector, delta, 0);
    }
}
