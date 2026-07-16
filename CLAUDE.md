# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->

This is a Sedona fork of official Uniswap V2 core (`contracts/`: `UniswapV2Factory`, `UniswapV2Pair`, `UniswapV2ERC20`), unmodified from upstream so far. It's a prep repo for a future confidential/FHE-integrated V2 DEX on Arbitrum — see `SedonaFi/v2-periphery` (sibling repo) for the router that depends on this one, and the DailyNote vault's `Projects/sedona-fhe/` for integration task tracking.

## Commands

- Install: `yarn`
- Build: `yarn compile` (runs `yarn clean` via `precompile`, then `waffle .waffle.json`)
- Lint: `yarn lint` (checks `./test/*.ts` only — contracts have no linter); fix with `yarn lint:fix`
- Test (all): `yarn test` (runs `mocha`; `pretest` auto-runs `yarn compile` first)
- Test (single file): `npx mocha --require ts-node/register test/UniswapV2Pair.spec.ts`

CI (`.github/workflows/CI.yml`) runs `yarn && yarn lint && yarn test` on Node 10.x/12.x.

Solidity `0.5.16` (`pragma solidity =0.5.16;`), Waffle config (`.waffle.json`): `evmVersion: istanbul`, optimizer `enabled: true, runs: 999999`. Do not change compiler version or optimizer settings without recomputing the pair init-code hash consumed downstream (see Architecture).

## Architecture

- `contracts/UniswapV2Factory.sol` — pair registry/deployer. `createPair(tokenA, tokenB)` sorts tokens (`token0 < token1`), then deploys a `UniswapV2Pair` via raw `create2` using `bytecode = type(UniswapV2Pair).creationCode` and `salt = keccak256(abi.encodePacked(token0, token1))`. Pair addresses are deterministic and computable off-chain without querying the factory.
- `contracts/UniswapV2Pair.sol` (extends `UniswapV2ERC20`) — holds two ERC20 reserves (`reserve0`/`reserve1`, packed with `blockTimestampLast` into one storage slot), implements `mint`/`burn` (liquidity provisioning, optional protocol fee via `_mintFee`/`kLast`) and `swap` (flash-swap-capable, enforces the constant-product invariant with a 0.3% fee). Updates TWAP accumulators `price0CumulativeLast`/`price1CumulativeLast` in `_update` using `UQ112x112` fixed-point math on every reserve change.
- `contracts/UniswapV2ERC20.sol` — LP-token base contract (standard ERC20) plus EIP-2612 `permit` (signature-based approvals) via a constructor-computed `DOMAIN_SEPARATOR` and `PERMIT_TYPEHASH` constant.
- `contracts/interfaces/` — `IERC20`, `IUniswapV2ERC20`, `IUniswapV2Factory`, `IUniswapV2Pair`, `IUniswapV2Callee`.
- `contracts/libraries/` — `SafeMath`, `UQ112x112`, `Math`.
- `contracts/test/ERC20.sol` — test-only mock ERC20.
- `test/` — Waffle + Mocha + Chai + TypeScript, with `test/shared/fixtures.ts` / `test/shared/utilities.ts` as shared helpers. Specs: `UniswapV2Factory.spec.ts`, `UniswapV2Pair.spec.ts`, `UniswapV2ERC20.spec.ts` (mint/burn/swap/reserves/fee/permit/EIP-712 coverage).

**Init-code-hash constraint:** no hash is hardcoded in this repo — it's derived at deploy time from `UniswapV2Pair`'s creation code. `SedonaFi/v2-periphery`'s `UniswapV2Library.pairFor` hardcodes `keccak256` of this pair's compiled bytecode to compute pair addresses off-chain. **Any edit to `UniswapV2Pair.sol` or its compiler/optimizer settings (e.g. future FHE changes) requires recomputing and patching that hash in the periphery repo**, or every router call there resolves the wrong pair address and reverts. This is the same failure mode that hit the Sedona V3 deploy (`PoolAddress.sol` init-code-hash mismatch).
