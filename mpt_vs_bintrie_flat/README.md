# MPT vs Binary Trie Benchmarks — Part 3 (Flat State)

Three-way performance comparison: Ethereum's Merkle Patricia Trie (MPT), Binary Trie group-depth 5 without flat state (BT-GD5), and Binary Trie group-depth 5 with flat state enabled (BT-GD5-flat). ERC20 workloads on the geth implementation.

[Full report](index.html) ·
[ethresear.ch post](ethresearch-post.md) ·
[Source analysis](FLAT_STATE_ANALYSIS.md) ·
[Procedure](BENCHMARK_PROCEDURE.md) ·
[Raw data](data/)

**Headline:** Flat state makes bintrie **1.8–2.4× faster than MPT** for read-heavy workloads and **2.5–3.8× faster per slot on read latency**. On write-heavy `erc20_approve`, bintrie-flat is statistically on par with MPT end-to-end (median +10%, not significant) but resolves ~2.4× fewer slots/sec — the bottleneck has shifted from `state_read` (resolved by flat state) to `trie_updates` (root recomputation, structural to the binary trie). Note MPT already serves SLOADs from its flat snapshot, so the read result is parity-plus, driven substantially by flat's 3× smaller DB and the prefetcher race (report §S3/§S6).

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

### Raw results (median per benchmark block, gas > 500K filter)

| Benchmark | Config | total_ms | read latency (µs/slot) | slots/sec (all phases) | storage cache hit |
|:----------|:-------|:---------|:--------|:----------|:------------------|
| erc20_balanceof | MPT | 5,264 | 135 | 6,980 | 6.9% |
| | BT-GD5 | 8,901 | 216 | 4,128 | 35.0% |
| | **BT-GD5-flat** | **658** | **55** | **12,486** | **11.3%** |
| mixed_sload_sstore | MPT | 3,352 | 135 | 6,987 | 9.5% |
| | BT-GD5 | 3,470 | 334 | 1,991 | 72.3% |
| | **BT-GD5-flat** | **660** | **35** | **16,520** | **42.0%** |
| erc20_approve | MPT | 939 | 139 | 8,715 | 14.8% |
| | BT-GD5 | 2,000 | 364 | 1,757 | 72.9% |
| | **BT-GD5-flat** | **1,030** | **46** | **3,555** | **41.4%** |

**Note on metrics**: the `read latency (µs/slot)` column is median `state_read_ms / storage_slots_read` (a single, consistent denominator across configs). The `slots/sec (all phases)` column is the median per-block `(slots_read + slots_written) / total_s`. The two diverge for `erc20_approve`: BT-GD5-flat reads each slot ~3× faster than MPT but spends ~80% of its block time in `trie_updates` (vs 31% for MPT), so end-to-end throughput is lower despite faster reads. §S4 of the report unpacks this. **Caveat:** the bintrie binaries' `storage_slots_written` counter is unreliable (BT-GD5 reports 0 on approve despite hashing), so BT-GD5's approve slots/sec is read-only — see report §S6.

**Note on aggregation**: all tables show **medians per block**, matching `analysis_results.json` (which also carries the Mann-Whitney U / bootstrap-CI hypothesis tests, robust to the long tails created by EIP-7825 multi-block fragmentation) and the graphs. Means per block run ~10-35% higher for the bintrie configs.

**Note on cache hit rates**: median per-block storage cache hit rates are MPT 7-15%, BT-GD5 35-73%, BT-GD5-flat 11-42% — **BT-GD5, not flat, shows the highest medians**. All bintrie configs run elevated vs MPT because of the same `stateReaderWithCache` prefetcher race documented in Part 2 ([`../mpt-vs-bintrie/CACHE_ANALYSIS.md`](../mpt-vs-bintrie/CACHE_ANALYSIS.md)). `total_ms` and `state_read_ms` remain the authoritative wall-clock metrics.

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
