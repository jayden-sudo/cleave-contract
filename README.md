# Cleave contracts

Solidity core of the **Cleave** protocol — a decentralized options exchange. Cleave splits a
collateral asset (native ETH or any ERC-20) into two complementary legs — **P** (cash / downside)
and **N** (upside) — that are *defined to always sum back to the deposit at any settlement price*.
That makes liquidations structurally impossible, and the oracle only has to be correct **once, at
maturity** (a "slow oracle"). No debt, no liquidation, no admin keys.

Implements the design from Vitalik's
[_Building index-tracking assets on top of options instead of debt_](https://ethresear.ch/t/building-index-tracking-assets-on-top-of-options-instead-of-debt/25036).

## The two halves

Deposit 1 unit into a *market* (a strike `S` and maturity `M`) and mint two ERC-20s. At maturity
price `x`:

| Token | UI name | Redeems | Behaves like |
|-------|---------|---------|--------------|
| **P** | cash half   | `min(1, S/x)` | the deposit with upside above `S` sold off — steady near `$S`, carries the downside |
| **N** | upside half | `max(0, 1 − S/x)` | a call option struck at `S` |

For **every** `x`, `P + N = 1` unit — collateral is always exactly enough to pay both legs.
`combine` (burn 1 P + 1 N → 1 unit) is the always-available exit, before or after settlement, and
needs no oracle. `settle` is permissionless once `block.timestamp ≥ maturity`, reads the oracle once
anchored to `M`, and locks the redemption fraction — so settle timing can't be gamed.

## Layout (`src/`)

```
Series.sol            escrow + split / combine / settle / redeem; native ETH or any ERC-20 collateral
SplitToken.sol        the P (cash) and N (upside) ERC-20 legs; mint/burn gated to their Series
SplitFactory.sol      get-or-create one market per (collateral, strike, maturity, oracle) — dedupes liquidity
Marketplace.sol       escrowed order book for the legs (list / buy / cancel), pull-payment proceeds
CleaveZap.sol         stateless Boost/Yield router over a Uniswap v3 P/USDC pool
MockOracle.sol        owner-settable oracle — DEV/LOCAL ONLY, never mainnet
interfaces/IPriceOracle.sol

amm/                  the oracle-anchored liquidity layer (Uniswap v4)
  OracleAnchoredHook.sol   v4 custom-curve hook: quotes P at a keeper guide price i ± dynamic fee,
                           clamped on-chain to the no-arb band (proPAMM principle). Only P needs an AMM.
  CleaveZapV4.sol          the v4 repoint of CleaveZap: Boost/Earn routed through the hook pool
  CleaveQuoteMath.sol      pure oracle-anchored quote math + decimal handling (unit-tested in isolation)

oracle/
  UniswapV3MedianOracle.sol   USD/ETH = median of three 1h Uniswap v3 TWAPs (USDC, USDT, DAI) — the canonical settlement oracle
  ChainlinkBenchmarkOracle.sol  Tier-B: any Chainlink USD feed, pinned-record settlement (validated round bracket)
  PythBenchmarkOracle.sol       Tier-B: Pyth Benchmarks, pinned-record settlement (unique benchmark update)
  PythLazerOracle.sol           Tier-B: Pyth Lazer signed feed (Lazer-only underlyings), immutable trusted signer
  libraries/                    vendored TickMath / FullMath ports + Median + UniV3OracleLib
  lazer/, interfaces/           vendored Pyth/Chainlink parsing libs + interfaces
```

**Two-oracle split.** Settlement always uses the slow median TWAP (`priceAt(maturity)`). The v4
hook quotes *trading* off a separate fast quote oracle, bounded by an on-chain no-arb clamp — a wrong
keeper can't push price past where arbitrage already allows, and the fast oracle never enters the
settlement path. The Tier-B oracles unlock non-ETH underlyings via a deterministic, trust-minimized
**pinned-record** pattern (the caller only relays data the feed already signed).

## Boost & Yield (one-click products)

`CleaveZap` / `CleaveZapV4` are stateless, ownerless routers — they custody funds only within a
single tx; slippage is bounded by caller-supplied minimum-out + deadline.

- **Boost** (`boostFull`) — send ETH; loop "split → sell P into the pool → swap back to ETH → split"
  (≤16 rounds, UI uses 12), walk away holding only the upside leg N. Defined-risk leverage, no
  liquidation price.
- **Yield / Earn** (`yieldBuy`) — send USDC; buy P at a discount to the strike floor.

`CleaveZap` runs over a passive Uniswap **v3** pool; `CleaveZapV4` repoints the P↔USDC hop to the
**v4** `OracleAnchoredHook` pool for oracle-anchored, ~size-independent fills.

## Build and test

```shell
forge build --sizes
forge test -vv                  # unit + 128k-call solvency invariant + halmos symbolic suite;
                                # fork tests self-skip without MAINNET_RPC_URL
MAINNET_RPC_URL=<rpc> forge test --match-contract "Fork|Integration" -vv
forge fmt
```

Toolchain is pinned: **solc 0.8.26** + **cancun** EVM (Uniswap v4 needs transient storage). Run
`git submodule update --init --recursive` if `forge-std` / `v4-core` / `v4-periphery` imports fail.

Proof bridge (run after **any** `Series` core change):

```shell
forge test --match-path 'test/Series.verity.t.sol' -vv
```

## Scripts (`script/`)

- `Deploy.s.sol` — local/anvil demo stack (CREATE2, seeded series + orders)
- `DeployMainnet.s.sol` — the immutable core: oracle, factory, marketplace, first series
- `DeployOracle.s.sol` — the median oracle alone
- `DeployOracleAmm.s.sol` / `DeployZapV4.s.sol` — the v4 hook pool + v4 zap
- `GrowCardinality.s.sol` / `CheckCardinality.s.sol` — grow / gate Uniswap observation buffers (settlement-liveness)

> **Never `--broadcast` to mainnet from an agent.** Mainnet deploys are a human runbook.

## Formal verification

The accounting core of `Series` (split / combine / settle / redeem) is **machine-proven in Lean 4**,
not just tested: the 1:1 backing identity pre-settlement, `f = min(1, S/x)` at settlement, and the
solvency inequality `pSupply·f + nSupply·(1 − f) ≤ collateral` preserved by every combine/redeem. 14
obligations discharge with no `sorry`, each re-checked against the compiled `Series.sol` by a Foundry
bridge. The settlement price is a free input to the proofs, so solvency holds for **any** price.

Covers the `Series` **core only** — not the oracle, `Marketplace`, or zap routers — and is not a
substitute for a full audit. **Storage slots 0–9 of `Series.sol` are frozen** (coupled to the Lean
model); do not reorder or insert.

## Status & safety

The contracts are **unaudited**; a full external audit gates the uncapped mainnet launch. The
`Series` core's solvency invariants are formally verified; the oracle and periphery (AMM hook, zap,
Tier-B oracles) are tested, not yet verified. The v4 hook / zap layer is the **mutable, non-core**
liquidity layer — it never touches the verified `Series` core, and a dead keeper can only widen/pause
swaps, never brick the `combine` exit. This is a faithful, tested implementation of the research
design, not a production deployment.

## License

MIT — see [LICENSE](LICENSE).
