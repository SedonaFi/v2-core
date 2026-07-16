// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.25;

import { CofheTest } from "@cofhe/foundry-plugin/contracts/CofheTest.sol";
import { CofheClient } from "@cofhe/foundry-plugin/contracts/CofheClient.sol";
import { InEuint64, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { Vm } from "forge-std/Vm.sol";

import { ConfidentialUniswapV2Factory } from "../src/ConfidentialUniswapV2Factory.sol";
import { ConfidentialUniswapV2Pair } from "../src/ConfidentialUniswapV2Pair.sol";
import { MockFHERC20 } from "../src/test/MockFHERC20.sol";

contract ConfidentialUniswapV2PairTest is CofheTest {
    uint256 constant LP_PKEY = 0xA11CE;
    uint256 constant TRADER_PKEY = 0xB0B;
    uint256 constant BACKEND_PKEY = 0xBEE5;

    CofheClient lp;
    CofheClient trader;
    CofheClient backend;

    MockFHERC20 tokenA;
    MockFHERC20 tokenB;
    /// @dev The factory sorts tokens by address (token0 < token1), which need not match the
    /// (tokenA, tokenB) creation order -- `token0`/`token1` always refer to the pair's actual
    /// sorted tokens so operator grants / balances / `zeroForOne` line up correctly.
    MockFHERC20 token0;
    MockFHERC20 token1;
    ConfidentialUniswapV2Factory factory;
    ConfidentialUniswapV2Pair pair;

    function setUp() public {
        deployMocks();

        lp = createCofheClient();
        lp.connect(LP_PKEY);
        trader = createCofheClient();
        trader.connect(TRADER_PKEY);
        backend = createCofheClient();
        backend.connect(BACKEND_PKEY);

        tokenA = new MockFHERC20("Token A", "TKA");
        tokenB = new MockFHERC20("Token B", "TKB");

        factory = new ConfidentialUniswapV2Factory(backend.account());
        address pairAddr = factory.createPair(address(tokenA), address(tokenB));
        pair = ConfidentialUniswapV2Pair(pairAddr);
        token0 = MockFHERC20(pair.token0());
        token1 = MockFHERC20(pair.token1());

        // Seed balances: LP gets enough of both tokens to bootstrap the pool, trader gets tokenIn
        // (token0, the `zeroForOne` swap leg) to swap with.
        token0.mint(lp.account(), 1_000_000e6);
        token1.mint(lp.account(), 1_000_000e6);
        token0.mint(trader.account(), 10_000e6);

        address lpAddr = lp.account();
        address traderAddr = trader.account();

        // Operator authorization (FR-P6): LP + trader grant the pair operator status so it can
        // pull via confidentialTransferFrom.
        vm.prank(lpAddr);
        token0.setOperator(address(pair), type(uint48).max);
        vm.prank(lpAddr);
        token1.setOperator(address(pair), type(uint48).max);
        vm.prank(traderAddr);
        token0.setOperator(address(pair), type(uint48).max);

        // Seed the pool (M0/FR-P8: pools must be seeded at creation, never fully drained).
        // NB: build every InEuint64/address arg *before* vm.prank -- vm.prank only affects the
        // very next call, and any inline call expression (including `lp.account()` or
        // `lp.createInEuint64(...)`) evaluated as a call argument would consume it before
        // `pair.mint` itself executes.
        InEuint64 memory seed0 = lp.createInEuint64(1_000_000e6);
        InEuint64 memory seed1 = lp.createInEuint64(1_000_000e6);
        vm.prank(lpAddr);
        pair.mint(seed0, seed1, lpAddr);
    }

    /// @dev MINIMUM_LIQUIDITY (1000 units) is permanently locked out of the bootstrap mint (never
    /// credited to any holder) so the pool can never be fully drained -- see the pair's
    /// `MINIMUM_LIQUIDITY` docstring.
    uint64 constant MINIMUM_LIQUIDITY = 1000;

    function test_poolIsSeeded() public {
        expectPlaintext(pair.confidentialReserve0(), uint64(1_000_000e6));
        expectPlaintext(pair.confidentialReserve1(), uint64(1_000_000e6));
        expectPlaintext(pair.confidentialLPBalanceOf(lp.account()), uint64(1_000_000e6 - MINIMUM_LIQUIDITY));
        expectPlaintext(pair.confidentialTotalLPSupply(), uint64(1_000_000e6));
    }

    /// @notice M0 exit criterion (PRD §8): one encrypted swap executes, and the swap amount is
    /// absent from calldata + emitted events -- only ciphertext handles / indicator ticks appear.
    function test_encryptedSwap_amountsAbsentFromCalldataAndEvents() public {
        uint64 swapAmount = 1_000e6;
        InEuint64 memory encIn = trader.createInEuint64(swapAmount);
        InEuint64 memory encMinOut = trader.createInEuint64(0);
        address traderAddr = trader.account();

        // The calldata for the swap tx carries only the ciphertext input struct (handle + proof),
        // never the plaintext amount -- assert the raw uint64 value doesn't appear in the encoded
        // call.
        bytes memory callData = abi.encodeCall(ConfidentialUniswapV2Pair.swap, (encIn, true, encMinOut, traderAddr));
        bool foundPlaintextAmount = _bytesContainUint64(callData, swapAmount);
        assertFalse(foundPlaintextAmount, "plaintext swap amount leaked into calldata");

        vm.recordLogs();
        vm.prank(traderAddr);
        euint64 out = pair.swap(encIn, true, encMinOut, traderAddr);

        // No emitted event's ABI-encoded data section should contain the raw plaintext swap
        // amount as a 32-byte word.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertFalse(_bytesContainUint64(logs[i].data, swapAmount), "plaintext swap amount leaked into an event");
        }

        // Trader can decrypt their own received output (ACL-gated) and it reflects the real
        // constant-product math (997/1000 fee): expected out for a 1,000,000/1,000,000 pool.
        uint256 expectedOut = _quote(swapAmount, 1_000_000e6, 1_000_000e6);
        expectPlaintext(out, uint64(expectedOut));
    }

    /// @notice SR-2 clamp-atomicity: a slippage-violating swap moves zero on BOTH legs -- the
    /// input is fully refunded, not partially pulled, and the output is zero.
    function test_clampAtomicity_slippageViolation_movesNothingOnEitherLeg() public {
        uint64 swapAmount = 1_000e6;
        uint256 realOut = _quote(swapAmount, 1_000_000e6, 1_000_000e6);
        // Demand far more than the pool could ever return -> must clamp to zero, not revert.
        uint64 impossibleMin = uint64(realOut) * 100;
        address traderAddr = trader.account();
        InEuint64 memory encIn = trader.createInEuint64(swapAmount);
        InEuint64 memory encMinOut = trader.createInEuint64(impossibleMin);

        vm.prank(traderAddr);
        euint64 out = pair.swap(encIn, true, encMinOut, traderAddr);

        // Output leg: zero.
        expectPlaintext(out, uint64(0));
        // Input leg: reserves unchanged (the pulled input was fully refunded).
        expectPlaintext(pair.confidentialReserve0(), uint64(1_000_000e6));
        expectPlaintext(pair.confidentialReserve1(), uint64(1_000_000e6));
        // Trader's tokenA balance is back to its pre-swap value (refunded), not debited.
        expectPlaintext(token0.confidentialBalanceOf(trader.account()), uint64(10_000e6));
    }

    /// @notice Sanity check for the mint/burn liquidity lifecycle: an LP who burns their entire
    /// (non-locked) position gets back what they put in, minus the permanently-locked
    /// MINIMUM_LIQUIDITY dust -- the pool is left seeded, never fully drained (FR-P8), so a later
    /// mint/burn/swap doesn't divide by zero.
    function test_burn_returnsSeededLiquidity_mintTinyDustLocked() public {
        address lpAddr = lp.account();
        // Requesting the full original 1,000,000e6 clamps to the LP's actual balance (which is
        // MINIMUM_LIQUIDITY short of that, permanently locked -- see MINIMUM_LIQUIDITY docstring).
        InEuint64 memory burnAmount = lp.createInEuint64(1_000_000e6);

        vm.prank(lpAddr);
        (euint64 out0, euint64 out1) = pair.burn(burnAmount, lpAddr);

        expectPlaintext(out0, uint64(1_000_000e6 - MINIMUM_LIQUIDITY));
        expectPlaintext(out1, uint64(1_000_000e6 - MINIMUM_LIQUIDITY));
        expectPlaintext(pair.confidentialReserve0(), uint64(MINIMUM_LIQUIDITY));
        expectPlaintext(pair.confidentialReserve1(), uint64(MINIMUM_LIQUIDITY));
        expectPlaintext(pair.confidentialTotalLPSupply(), uint64(MINIMUM_LIQUIDITY));
        expectPlaintext(pair.confidentialLPBalanceOf(lpAddr), uint64(0));

        // FR-P8 regression: a near-fully-drained pool (reserves == MINIMUM_LIQUIDITY, not zero)
        // must still accept a new mint -- before the MINIMUM_LIQUIDITY lock, burning 100% of
        // supply left reserves/supply at exactly zero and every later mint/burn divided by zero.
        InEuint64 memory remint0 = lp.createInEuint64(500e6);
        InEuint64 memory remint1 = lp.createInEuint64(500e6);
        vm.prank(lpAddr);
        pair.mint(remint0, remint1, lpAddr);
        expectPlaintext(pair.confidentialReserve0(), uint64(MINIMUM_LIQUIDITY + 500e6));
    }

    function _quote(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 amountInWithFee = (amountIn * 997) / 1000;
        return (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);
    }

    function _bytesContainUint64(bytes memory haystack, uint64 needle) internal pure returns (bool) {
        if (needle == 0 || haystack.length < 32) return false;
        bytes32 word = bytes32(uint256(needle));
        for (uint256 i = 0; i + 32 <= haystack.length; i++) {
            bytes32 chunk;
            assembly {
                chunk := mload(add(add(haystack, 32), i))
            }
            if (chunk == word) return true;
        }
        return false;
    }
}
