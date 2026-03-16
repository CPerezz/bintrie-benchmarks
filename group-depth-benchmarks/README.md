# Group Depth Benchmarks

Performance comparison of binary trie group-depth configurations on the geth implementation.

## Campaign

| Parameter | Value |
|:----------|:------|
| Machine | QEMU VM -- 8 vCPUs, 30 GB RAM, 3.9 TB SSD, Ubuntu 24.04 LTS |
| Database | ~360 GB, ~400M accounts + storage slots per configuration |
| Configurations | GD-1 through GD-8 (Pebble, 4KB block size) |
| Protocol | Cold cache (OS page cache dropped + Pebble cache=0 between runs) |
| Runs | 10 per benchmark per config; run 1 excluded (residual warmth) |
| Gas target | 100M gas per block |

### Benchmarks

| Benchmark | Type | Access pattern | Measures |
|:----------|:-----|:---------------|:---------|
| sload_benchmark | Synthetic | Sequential | Raw read latency |
| sstore_variants | Synthetic | Sequential | Raw write latency (multiple sub-variants) |
| erc20_balanceof | ERC20 | Random (keccak-hashed) | Read-only contract calls |
| erc20_approve | ERC20 | Random (keccak-hashed) | Write contract calls |
| mixed_sload_sstore | Mixed | Random | Interleaved reads + writes |

### Data completeness

| Benchmark | GD-1 | GD-2 | GD-3 | GD-4 | GD-5 | GD-6 | GD-7 | GD-8 |
|:----------|:-----|:-----|:-----|:-----|:-----|:-----|:-----|:-----|
| sload_benchmark | 9 runs | 9 runs | -- | 9 runs | -- | -- | -- | -- |
| sstore_variants | 9 runs | 9 runs | -- | 9 runs | -- | -- | -- | 4 runs |
| erc20_balanceof | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs |
| erc20_approve | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs |
| mixed_sload_sstore | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 9 runs | 5 runs | 9 runs |

Synthetic benchmarks are only available for GD-1, 2, 4 (and partially GD-8). All eight group depths have complete ERC20 data.

GD-3/5/6/7 ERC20 data was re-run (Phase 3) with verified cold-cache protocol — `sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'` confirmed successful on every run (120+ drops, 0 failures). The original Phase 2 campaign's cold-cache drops silently failed due to `sudo -n` credential expiry, producing unreliable data.

## Results

**The sweet spot is GD-5 or GD-6**, depending on workload. GD-5 is the write champion (6.94 Mgas/s, +7% over GD-4). GD-6 leads reads (6.39 Mgas/s) and mixed workloads (6.27 Mgas/s). GD-7 confirms the inflection — performance degrades past GD-6 on all benchmarks.

The mechanism: each trie node at group depth *g* contains an internal binary subtree with 2^g - 1 nodes that must be rehashed on every write. GD-5 (31 internal nodes) finds the write sweet spot between path length (~52 nodes) and per-node rehashing cost. At GD-6 (63 internal nodes), rehashing costs rise moderately (283 ms vs 242 ms for GD-5), but read improvements at GD-6 still outpace the write penalty for read-heavy and mixed workloads.

| Criterion | GD-4 | GD-5 | GD-6 | GD-7 | GD-8 |
|:----------|:-----|:-----|:-----|:-----|:-----|
| Reads (Mgas/s) | 5.46 | 6.11 | **6.39** | 6.04 | 5.59 |
| Writes (Mgas/s) | 6.47 | **6.94** | 6.41 | 5.81 | 4.47 |
| Mixed (Mgas/s) | 5.13 | 6.09 | **6.27** | 5.87 | 5.43 |

## Contents

- [`index.html`](index.html) -- Full interactive report with SVG diagrams
- [`ethresearch-post.md`](ethresearch-post.md) -- Markdown version for ethresear.ch
- [`data/`](data/) -- Raw benchmark CSVs (per-block metrics for all runs)
- [`graphs/`](graphs/) -- Data visualizations
- [`diagrams/`](diagrams/) -- Explanatory diagrams
- [`logs/`](logs/) -- Raw geth and test runner logs per configuration
- [`scripts/`](scripts/) -- Automation scripts for the benchmark campaign:
  - `generate_dbs.sh` -- Generate state DBs with state-actor + deploy ERC20 via spamoor
  - `run_erc20_benchmarks.sh` -- Run ERC20 benchmarks with cold-cache protocol via execution-specs
  - `extract_csv.py` -- Parse geth slow-block JSON logs into per-benchmark and consolidated CSVs
  - `analyze_data.py` -- Statistical analysis (medians, Mann-Whitney U, CV%, percentage diffs)
  - `generate_graphs.py` -- Generate all benchmark visualization PNGs (dark/light themes)

## Reproducing

Both shell scripts are parameterized via the `GROUP_DEPTHS` environment variable and accept any space-separated list of group depth values. All tool paths at the top of each script must be edited for your environment.

### Prerequisites

| Tool | Purpose |
|:-----|:--------|
| [state-actor](https://github.com/ethpandaops/state-actor) | Generates the 400GB binary-trie databases |
| [geth (bintrie branch)](https://github.com/gballet/go-ethereum) | Binary trie-enabled geth fork |
| [spamoor](https://github.com/ethpandaops/spamoor) | Deploys ERC20 contracts onto the generated DBs |
| [execution-specs](https://github.com/ethereum/execution-specs) | Benchmark test harness (pytest-based) |
| [uv](https://github.com/astral-sh/uv) | Python package runner used by execution-specs |

### Step 1: Generate DBs + deploy ERC20

```bash
GROUP_DEPTHS="1 2 4 8" bash scripts/generate_dbs.sh
```

This runs two phases:
1. **state-actor** generates a ~400GB binary-trie DB per group depth (`-seed 25519` for determinism)
2. **spamoor** deploys a small ERC20 contract on each DB, writing `stubs.json` with the contract address

### Step 2: Run benchmarks

```bash
GROUP_DEPTHS="1 2 4 8" bash scripts/run_erc20_benchmarks.sh
```

Runs 3 ERC20 benchmarks x 10 runs per config, cold-cache between every run. Produces per-benchmark geth logs and consolidated CSVs.

Override the number of runs with `NUM_RUNS`:
```bash
GROUP_DEPTHS="4" NUM_RUNS=5 bash scripts/run_erc20_benchmarks.sh
```

### Important warnings

**Group depth must match between state-actor and geth.** When geth opens a database, `--bintrie.groupdepth` must be set to the same value used by state-actor when generating that DB. Using a different value **will corrupt the database irreversibly** -- the on-disk trie layout won't match what geth expects.

**Spamoor's private key must match state-actor's injected account.** The `--privkey` passed to spamoor must correspond to the account given to state-actor's `-inject-accounts` flag. The scripts default to Anvil's well-known key (`0xac09...ff80`) because state-actor pre-funds that account during generation.
