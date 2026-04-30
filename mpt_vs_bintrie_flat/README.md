# MPT vs Binary Trie Benchmarks — Part 3 (Flat State)

Three-way performance comparison: Ethereum's Merkle Patricia Trie (MPT), Binary Trie group-depth 5 without flat state (BT-GD5), and Binary Trie group-depth 5 with flat state enabled (BT-GD5-flat). ERC20 workloads on the geth implementation.

[Full report](index.html) ·
[ethresear.ch post](ethresearch-post.md) ·
[Source analysis](FLAT_STATE_ANALYSIS.md) ·
[Procedure](BENCHMARK_PROCEDURE.md) ·
[Raw data](data/)

**Headline:** Flat state makes bintrie **2.0–2.3× faster than MPT** for read-heavy workloads and **3.0–3.7× faster per slot on read latency**. For write-heavy workloads (`erc20_approve`), bintrie-flat is still ~25% slower than MPT end-to-end — the bottleneck has shifted from `state_read` (resolved by flat state) to `trie_updates` (root recomputation, structural to the binary trie).

## Campaign

| Parameter | Value |
|:----------|:------|
| Machine | Bare metal — AMD EPYC 9454P 48-Core (96 threads), 126 GB RAM, 3.5 TB SSD (md RAID), Ubuntu 24.04 LTS *(same hardware as Part 2)* |
| Configurations | `mpt`, `bt-gd5`, `bt-gd5-flat` |
| Databases | MPT: 1.6 TB, ~2.53 GB ERC20 bloat; BT-GD5: 1.4 TB, ~2.76 GB ERC20 bloat; BT-GD5-flat: 507 GB, ~2.0 GB ERC20 bloat |
| Protocol | Cold cache (OS page cache dropped + Pebble cache=0 between runs) |
| Gas target | 100M per block |
| ERC20 contract | `0xF852dB3A94Ee27370B47011eBD1610e7718802Bd` |
| Seed account | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (~1B ETH) |

### Geth binaries

| Binary | Source | Commit | Built |
|:-------|:-------|:-------|:------|
| `geth-mpt` | go-ethereum master | `5d0e18f7` | 2026-03-25 |
| `geth-bintrie` (BT-GD5) | bintrie fork | `991300c4` | 2026-03-19 |
| `geth-bintrie` (BT-GD5-flat) | `bintrie-flat-state` branch | `7d2e7cbe` | 2026-04-27 |

### State-actor

| Binary | Commit | Notes |
|:-------|:-------|:------|
| `state-actor-bintrie` | PR#19 `5365b8f` + local fixes | Flat-state metadata fixes: `WriteDatabaseVersion(9)`, `"v"` prefix on PathDB metadata, `IsBintrie:true` in `SnapshotGenerator` |

### Benchmarks

| Benchmark | Type | Access pattern | Measures |
|:----------|:-----|:---------------|:---------|
| erc20_balanceof | ERC20 | Random (keccak-hashed) | Read-only contract calls (SLOAD) |
| erc20_approve | ERC20 | Random (keccak-hashed) | Write contract calls (SSTORE) |
| mixed_sload_sstore | Mixed | Random | Interleaved 50-50 reads + writes |

### Data completeness

| Benchmark | MPT | BT-GD5 | BT-GD5-flat |
|:----------|:----|:-------|:------------|
| erc20_balanceof | 100 runs | 10 runs | 10 runs (~31 blocks) |
| erc20_approve | 100 runs | 10 runs | 10 runs (~20 blocks) |
| mixed_sload_sstore | 100 runs | 10 runs | 10 runs (~20 blocks) |

BT-GD5-flat produces multiple blocks per run because EIP-7825 (Osaka) caps per-transaction gas at 16M, splitting the 100M-gas benchmark into ~6 transactions across 2-3 blocks.

### Raw results (mean per benchmark block, gas > 500K filter)

| Benchmark | Config | total_ms | read latency (µs/slot) | slots/sec (all phases) | storage cache hit |
|:----------|:-------|:---------|:--------|:----------|:------------------|
| erc20_balanceof | MPT | 5,280 | 135 | 6,958 | 7.1% |
| | BT-GD5 | 10,620 | 255 | 3,460 | 38.5% |
| | **BT-GD5-flat** | **853** | **45** | **13,873** | **68.1%** |
| mixed_sload_sstore | MPT | 3,349 | 134 | 6,993 | 9.0% |
| | BT-GD5 | 4,638 | 287 | 2,762 | 44.8% |
| | **BT-GD5-flat** | **729** | **36** | **16,040** | **84.5%** |
| erc20_approve | MPT | 937 | 69 | 8,741 | 14.5% |
| | BT-GD5 | 2,242 | 334 | 1,790 | 64.6% |
| | **BT-GD5-flat** | **1,169** | **23** | **3,494** | **83.8%** |

**Note on metrics**: the `read latency (µs/slot)` column is `state_read_ms / storage_slots_read` — the cost of resolving each storage slot from disk (or flat-state blob). The `slots/sec (all phases)` column is `(slots_read + slots_written) / total_ms`, including `state_read`, `trie_updates`, EVM execution, and commit. The two diverge for `erc20_approve`: BT-GD5-flat reads each slot 3× faster than MPT but spends 85% of its block time in `trie_updates` (vs 31% for MPT), so end-to-end throughput is lower despite faster reads. §S4 of the report unpacks this phase shift.

**Note on aggregation**: tables in this report show **means per block** (matching `FLAT_STATE_ANALYSIS.md`). The companion `analysis_results.json` carries **medians** for the Mann-Whitney U / bootstrap-CI hypothesis tests, which are robust to the long tails created by EIP-7825 multi-block fragmentation. Mean and median can diverge by ~10-20% on the bintrie configs; both views are valid and serve different purposes.

**Note on cache hit rates**: BT-GD5-flat shows the highest rates (68-84%). The cause is the same `stateReaderWithCache` prefetcher race documented in Part 2 ([`../mpt-vs-bintrie/CACHE_ANALYSIS.md`](../mpt-vs-bintrie/CACHE_ANALYSIS.md)) — when reads are faster, the prefetcher wins more races. `total_ms` and `state_read_ms` remain the authoritative wall-clock metrics.

## Contents

- [`FLAT_STATE_ANALYSIS.md`](FLAT_STATE_ANALYSIS.md) — Source analysis (3-way comparison, mechanism, caveats)
- [`BENCHMARK_PROCEDURE.md`](BENCHMARK_PROCEDURE.md) — End-to-end procedure (DB gen, deployment, runs, extraction)
- [`ethresearch-post.md`](ethresearch-post.md) — Concise Part 3 post for ethresear.ch
- [`index.html`](index.html) — Self-contained dark-themed report
- [`data/`](data/) — Raw benchmark CSVs (per-block metrics for all runs, all 3 configs)
- [`graphs/`](graphs/) — Dark-theme PNGs
- [`graphs-light/`](graphs-light/) — Light-theme PNGs (used in ethresear.ch markdown)
- [`logs/`](logs/) — Raw geth + test logs per configuration
- [`scripts/`](scripts/) — Automation:
  - `generate_db.sh` — DB generation
  - `run_benchmarks.sh` — Cold-cache run loop
  - `extract_csv.py` — Slow-block JSON → CSV
  - `analyze_data.py` — Statistical aggregation (3-way)
  - `generate_graphs.py` — PNG generation (3-way + flat-specific)
- [`analysis_results.json`](analysis_results.json) — Aggregated metrics

## Procedure

See [`BENCHMARK_PROCEDURE.md`](BENCHMARK_PROCEDURE.md) for the full pipeline. Brief summary:

1. **Database generation** — `state-actor` creates a Pebble DB with trie nodes (`"v"` namespace) and stem blobs (`"vX"` + 31-byte stem). Genesis is configured with `EnableVerkleAtGenesis=true` and `DatabaseVersion=9`.
2. **ERC20 deployment** — `spamoor erc20_bloater` deploys an ERC20 contract with ~2-5 GB of storage slots over a gradual gas-limit ramp.
3. **Benchmark execution** — cold-cache runs with `--cache 0`, OS page cache dropped between every run, `--debug.logslowblock=0` to capture every block's timing JSON.
4. **CSV extraction** — `extract_csv.py` parses geth slow-block logs into per-config and consolidated CSVs.
5. **Analysis + graphs** — `analyze_data.py` produces `analysis_results.json`; `generate_graphs.py` renders the 7 graphs in dark + light themes.

## Reproducing

### Prerequisites

| Tool | Purpose |
|:-----|:--------|
| [state-actor](https://github.com/ethpandaops/state-actor) | Generates the state databases (PR#19 + flat-state metadata fixes) |
| [geth (master)](https://github.com/ethereum/go-ethereum) | Upstream geth for MPT |
| [geth (bintrie-flat-state branch)](https://github.com/CPerezz/go-ethereum) | Binary trie geth with flat-state support |
| [spamoor](https://github.com/ethpandaops/spamoor) | Deploys ERC20 contracts |
| [execution-specs](https://github.com/ethereum/execution-specs) | Pytest-based benchmark harness |
| [uv](https://github.com/astral-sh/uv) | Python runner for execution-specs |

### Important warnings

**Group depth must match between state-actor and geth.** When geth opens a bintrie database, `--bintrie.groupdepth` must be set to the same value used by state-actor when generating that DB. A mismatch will corrupt the database irreversibly.

**State-actor flat-state metadata fixes are required.** Without `WriteDatabaseVersion(9)`, the `"v"` prefix on PathDB metadata, and `IsBintrie:true` in `SnapshotGenerator`, geth will ignore the stem-blob layer entirely and either treat the DB as uninitialized or trigger snapshot regeneration on startup.

**EIP-7825 (Osaka) effect on block shapes.** The bintrie-flat-state branch activates Osaka at genesis, which caps individual transaction gas at 16M (`params.MaxTxGas = 1 << 24`). The 100M-gas benchmarks split into ~6 transactions landing across 2-3 blocks. Use per-slot metrics (`µs/slot`, `slots/s`) for cross-config comparisons rather than per-block totals.

**Spamoor's private key must match state-actor's injected account.** The `--privkey` for spamoor must correspond to the account given to state-actor's `-inject-accounts` flag.
