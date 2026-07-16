// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { FHE, euint64, euint128, ebool, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import { ConfidentialUniswapV2ERC20 } from "./ConfidentialUniswapV2ERC20.sol";
import { IConfidentialUniswapV2Pair } from "./interfaces/IConfidentialUniswapV2Pair.sol";
import { IConfidentialUniswapV2Factory } from "./interfaces/IConfidentialUniswapV2Factory.sol";
import { IFHERC20Minimal } from "./interfaces/IFHERC20Minimal.sol";

/// @title ConfidentialUniswapV2Pair
/// @notice Uniswap-V2-style constant-product pool trading two ERC-7984 (FHERC20) tokens on
/// encrypted `euint64` reserves. Every swap's amountIn/amountOut, the reserves, and LP balances
/// are ciphertext on-chain (ConfidentialV2 DEX PRD, 2026-07-15).
///
/// Deliberately additive/self-contained: this is a NEW compilation unit (solc 0.8.25, Foundry)
/// living outside `contracts/` so it never touches the vanilla 0.5.16 Waffle build or the
/// existing `UniswapV2Pair` init-code hash the periphery router hardcodes.
///
/// Key invariants (see PRD SR-1/SR-2/FR-P3/FR-P4/FR-P7):
///  - SR-1: the constant-product math is computed in `euint128` intermediates. A pure-`euint64`
///    product overflows at trivial pool sizes; 128-bit headroom makes it a non-issue.
///  - SR-2/FR-P3: swap never reverts on insufficient balance or slippage violation. ONE shared
///    `ebool` condition (`ok`) gates the payout, the reserve updates, AND (via a same-tx refund)
///    the net input retained by the pool — so a failing swap always nets to "zero in, zero out".
///  - FR-P4/SR-3: the pool never mints eTokens; it only moves balances FHERC20 wrappers already
///    backed.
///  - FR-P7: no encrypted sqrt exists in CoFHE, so the first mint is a declared-unit bootstrap
///    (first LP's shares := deposited token0 amount); every later mint is proportional via
///    `FHE.min`, computed in `euint128` to avoid overflow on `dx * totalSupply`.
contract ConfidentialUniswapV2Pair is ConfidentialUniswapV2ERC20, IConfidentialUniswapV2Pair {
    uint256 private constant FEE_NUMERATOR = 997;
    uint256 private constant FEE_DENOMINATOR = 1000;

    /// @dev Mirrors vanilla UniswapV2Pair's MINIMUM_LIQUIDITY: permanently locked into
    /// `_totalLPSupply` (never credited to any holder) on the bootstrap mint, so `_totalLPSupply`
    /// can never be fully burned back to zero. Without this, fully draining a pool (burning 100%
    /// of supply) leaves `_totalLPSupply == 0` and `reserve0 == reserve1 == 0`, and every later
    /// `mint`/`burn` reverts on `FHE.div`'s zero-divisor check (`supply` in `burn`, `reserve0`/
    /// `reserve1` in `mint`'s proportional branch) -- a permanent DoS that violates FR-P8 ("pools
    /// must be... never fully drained").
    uint64 private constant MINIMUM_LIQUIDITY = 1000;

    address public factory;
    address public token0;
    address public token1;

    euint64 private reserve0;
    euint64 private reserve1;

    bool private _initialized;
    /// @dev Foundry-mock reentrancy guard equivalent (no external callback surface exists here —
    /// FR-R4/no swap-callback — but FHERC20 hooks (`confidentialTransferAndCall`-style receivers)
    /// are avoided entirely by only ever calling the plain `confidentialTransfer(From)` overloads).
    bool private _entered;

    modifier nonReentrant() {
        require(!_entered, "CUniV2: REENTRANT");
        _entered = true;
        _;
        _entered = false;
    }

    constructor() {
        factory = msg.sender;
    }

    /// @dev Called once by the factory right after CREATE2 deployment, mirroring vanilla
    /// UniswapV2Pair. Keeping the constructor argument-free keeps `type(ConfidentialUniswapV2Pair).creationCode`
    /// (and therefore the CREATE2 init-code hash) identical for every pair.
    function initialize(address _token0, address _token1) external override {
        require(msg.sender == factory, "CUniV2: FORBIDDEN");
        require(!_initialized, "CUniV2: ALREADY_INITIALIZED");
        _initialized = true;
        token0 = _token0;
        token1 = _token1;
    }

    function confidentialLPBalanceOf(
        address owner
    ) public view override(ConfidentialUniswapV2ERC20, IConfidentialUniswapV2Pair) returns (euint64) {
        return super.confidentialLPBalanceOf(owner);
    }

    function confidentialTotalLPSupply()
        public
        view
        override(ConfidentialUniswapV2ERC20, IConfidentialUniswapV2Pair)
        returns (euint64)
    {
        return super.confidentialTotalLPSupply();
    }

    function confidentialReserve0() external view override returns (euint64) {
        return reserve0;
    }

    function confidentialReserve1() external view override returns (euint64) {
        return reserve1;
    }

    function _backend() internal view returns (address) {
        return IConfidentialUniswapV2Factory(factory).backendQuoteAddress();
    }

    /// @dev FR-C6a: after every reserve write, grant the backend quote service read access so it
    /// can `decryptForView` exact reserves off-chain (gasless, no on-chain publish). Accepted
    /// trade-off per PRD PR-1a: the operator can reconstruct trades, the public cannot.
    function _allowBackendReserves() internal {
        address backend = _backend();
        if (backend != address(0)) {
            FHE.allow(reserve0, backend);
            FHE.allow(reserve1, backend);
        }
    }

    // =========================================================================
    //  Liquidity
    // =========================================================================

    function mint(
        InEuint64 calldata amount0Desired,
        InEuint64 calldata amount1Desired,
        address to
    ) external override nonReentrant returns (euint64 liquidity) {
        // Decode the InEuint64 HERE (msg.sender == the caller the client signed for) -- decoding
        // it one hop further down inside the token contract would see msg.sender == this pool,
        // not the real caller, and fail ZK-signature verification. Then explicitly `FHE.allow`
        // each token its own decoded amount before the pull: the pool is auto-granted access to
        // values it computes, but the *token* contract needs its own grant to operate on them
        // inside `_update` (a fresh handle's implicit access does not propagate to a callee).
        euint64 want0 = FHE.asEuint64(amount0Desired);
        euint64 want1 = FHE.asEuint64(amount1Desired);
        FHE.allow(want0, token0);
        FHE.allow(want1, token1);

        // Operator pull, no callback (FR-P6/FR-R4). If the user under-authorized the operator or
        // under-funded, FHERC20's own zero-replacement clamps the actual pulled amount down --
        // there is nothing further for the pool to clamp here.
        euint64 actual0 = IFHERC20Minimal(token0).confidentialTransferFrom(msg.sender, address(this), want0);
        euint64 actual1 = IFHERC20Minimal(token1).confidentialTransferFrom(msg.sender, address(this), want1);

        if (!_lpInitialized) {
            // FR-P7: declared-unit bootstrap. No encrypted sqrt exists in CoFHE; the first LP's
            // shares are set to the deposited token0 amount, minus a MINIMUM_LIQUIDITY permanently
            // locked into total supply (never credited to any holder -- see the constant's
            // docstring). Economically irrelevant unit choice -- every later mint is proportional
            // (FHE.min below), so it only fixes the LP share/token0 exchange rate for this one
            // pool, forever. Assumes the bootstrap deposit comfortably exceeds MINIMUM_LIQUIDITY,
            // same assumption vanilla UniswapV2Pair makes (PRD FR-P8: pools are operator-seeded).
            //
            // Known limitation (accepted, not fixed here): the bootstrap credits shares from
            // `actual0` alone, ignoring `actual1`'s ratio. A first LP who seeds a lopsided ratio
            // (e.g. token0=1, token1=huge) can round later depositors' proportional share
            // (FHE.min below) down to zero even though their deposit is accepted. This mirrors
            // every constant-product AMM's assumption that LPs add liquidity at the *current*
            // pool ratio; it is not the classic donation/inflation attack (not exploitable here,
            // since reserves are pure internal deltas, never derived from `confidentialBalanceOf`)
            // but is a real rounding risk for an adversarial first LP. Mitigation is operational
            // (PRD FR-P8: the operator seeds pools, not an arbitrary first caller), not coded.
            liquidity = FHE.sub(actual0, FHE.asEuint64(MINIMUM_LIQUIDITY));
            _totalLPSupply = FHE.add(_totalLPSupply, FHE.asEuint64(MINIMUM_LIQUIDITY));
            FHE.allowThis(_totalLPSupply);
            _lpInitialized = true;
        } else {
            // Proportional mint: liquidity = min(dx * S / x, dy * S / y), in euint128
            // intermediates (SR-1) since dx * S can overflow euint64 well before either operand
            // individually would.
            euint128 dx = FHE.asEuint128(actual0);
            euint128 dy = FHE.asEuint128(actual1);
            euint128 supply = FHE.asEuint128(_totalLPSupply);
            euint128 x = FHE.asEuint128(reserve0);
            euint128 y = FHE.asEuint128(reserve1);

            euint128 share0 = FHE.div(FHE.mul(dx, supply), x);
            euint128 share1 = FHE.div(FHE.mul(dy, supply), y);
            liquidity = FHE.asEuint64(FHE.min(share0, share1));
        }

        _mintLP(to, liquidity);

        reserve0 = FHE.add(reserve0, actual0);
        reserve1 = FHE.add(reserve1, actual1);
        FHE.allowThis(reserve0);
        FHE.allowThis(reserve1);
        _allowBackendReserves();

        emit ConfidentialMint(msg.sender, to);
    }

    function burn(
        InEuint64 calldata liquidityIn,
        address to
    ) external override nonReentrant returns (euint64 amount0, euint64 amount1) {
        require(_lpInitialized, "CUniV2: NO_LIQUIDITY");

        euint64 requested = FHE.asEuint64(liquidityIn);
        // Pre-burn snapshot: proportional payout is relative to supply/reserves *before* this
        // burn's debit, matching vanilla V2 semantics.
        euint128 supply = FHE.asEuint128(_totalLPSupply);
        euint128 x = FHE.asEuint128(reserve0);
        euint128 y = FHE.asEuint128(reserve1);

        // Clamped, never-revert burn: caps `requested` to msg.sender's actual LP balance.
        euint64 burned = _burnLP(msg.sender, requested);
        euint128 burned128 = FHE.asEuint128(burned);

        amount0 = FHE.asEuint64(FHE.div(FHE.mul(burned128, x), supply));
        amount1 = FHE.asEuint64(FHE.div(FHE.mul(burned128, y), supply));

        reserve0 = FHE.sub(reserve0, amount0);
        reserve1 = FHE.sub(reserve1, amount1);
        FHE.allowThis(reserve0);
        FHE.allowThis(reserve1);
        _allowBackendReserves();

        // Grant each token access to its own payout amount before the call -- see `mint`'s note
        // on why a freshly computed handle needs an explicit grant to the callee contract.
        FHE.allow(amount0, token0);
        FHE.allow(amount1, token1);
        IFHERC20Minimal(token0).confidentialTransfer(to, amount0);
        IFHERC20Minimal(token1).confidentialTransfer(to, amount1);

        emit ConfidentialBurn(msg.sender, to);
    }

    // =========================================================================
    //  Swap
    // =========================================================================

    /// @notice Constant-product swap with a 0.3% fee, clamped (never reverting) on insufficient
    /// pool solvency or violated slippage.
    /// @dev SR-2 atomicity: `ok` is the single encrypted condition that gates (a) how much of the
    /// pulled input the pool keeps (the rest is refunded in the same tx), (b) the output payout,
    /// and (c) both reserve updates. The actual pull happens first (FHERC20's own zero-
    /// replacement already yields 0 on insufficient balance -- PRD's "insufficient-balance pull
    /// auto-yields out=0"); if `ok` is false for any other reason (e.g. slippage), the full pulled
    /// amount is refunded via `FHE.select`-gated `confidentialTransfer`, so the net effect is
    /// always "both legs execute in full, or both are zero" -- never a partial pull.
    function swap(
        InEuint64 calldata amountIn,
        bool zeroForOne,
        InEuint64 calldata minAmountOut,
        address to
    ) external override nonReentrant returns (euint64 amountOut) {
        euint64 minOut = FHE.asEuint64(minAmountOut);

        address tokenIn = zeroForOne ? token0 : token1;
        address tokenOut = zeroForOne ? token1 : token0;

        // Decode the InEuint64 HERE (msg.sender == the real caller the client signed for), then
        // explicitly grant tokenIn access to the decoded handle -- see `mint` for why (a fresh
        // handle's implicit access does not propagate to a callee contract).
        euint64 amtIn = FHE.asEuint64(amountIn);
        FHE.allow(amtIn, tokenIn);

        // Operator pull (FR-P6/FR-R4, no swap-callback). Already clamps to zero internally if the
        // user's balance is insufficient.
        euint64 actualIn = IFHERC20Minimal(tokenIn).confidentialTransferFrom(msg.sender, address(this), amtIn);

        euint64 reserveIn = zeroForOne ? reserve0 : reserve1;
        euint64 reserveOut = zeroForOne ? reserve1 : reserve0;

        // out = reserveOut * amountInWithFee / (reserveIn + amountInWithFee), euint128
        // intermediates (SR-1, highest-severity requirement -- a pure-euint64 product overflows
        // at trivial pool sizes).
        euint128 actualIn128 = FHE.asEuint128(actualIn);
        euint128 reserveIn128 = FHE.asEuint128(reserveIn);
        euint128 reserveOut128 = FHE.asEuint128(reserveOut);

        euint128 amountInWithFee = FHE.div(FHE.mul(actualIn128, FHE.asEuint128(FEE_NUMERATOR)), FHE.asEuint128(FEE_DENOMINATOR));
        euint128 numerator = FHE.mul(reserveOut128, amountInWithFee);
        euint128 denominator = FHE.add(reserveIn128, amountInWithFee);
        euint64 rawOut = FHE.asEuint64(FHE.div(numerator, denominator));

        // ONE shared condition: solvency AND slippage.
        ebool solvent = FHE.lte(rawOut, reserveOut);
        ebool meetsMin = FHE.gte(rawOut, minOut);
        ebool ok = FHE.and(solvent, meetsMin);

        euint64 zero = FHE.asEuint64(0);
        euint64 netIn = FHE.select(ok, actualIn, zero);
        euint64 refund = FHE.select(ok, zero, actualIn);
        amountOut = FHE.select(ok, rawOut, zero);

        // Refund whatever portion of the pull is not kept, under the SAME `ok` used for the
        // payout -- this is what makes the pull and the payout share one gate even though the
        // real token movement (transferFrom) already executed above. Each token needs an
        // explicit grant on the handle it's about to operate on (see `mint`'s note).
        FHE.allow(refund, tokenIn);
        FHE.allow(amountOut, tokenOut);
        IFHERC20Minimal(tokenIn).confidentialTransfer(msg.sender, refund);
        IFHERC20Minimal(tokenOut).confidentialTransfer(to, amountOut);

        if (zeroForOne) {
            reserve0 = FHE.add(reserve0, netIn);
            reserve1 = FHE.sub(reserve1, amountOut);
        } else {
            reserve1 = FHE.add(reserve1, netIn);
            reserve0 = FHE.sub(reserve0, amountOut);
        }
        FHE.allowThis(reserve0);
        FHE.allowThis(reserve1);
        _allowBackendReserves();

        emit ConfidentialSwap(msg.sender, to, zeroForOne);
    }
}
