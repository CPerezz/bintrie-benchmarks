# Group Depth Benchmarks

Performance comparison of binary trie group-depth configurations on the geth implementation.

## Campaign

| Parameter | Value |
|:----------|:------|
| Machine | QEMU VM -- 8 vCPUs, 30 GB RAM, 3.9 TB SSD, Ubuntu 24.04 LTS |
| Database | ~360 GB, ~400M accounts + storage slots per configuration |
| Configurations | GD-1, GD-2, GD-4, GD-8 (Pebble, 4KB block size) |
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

| Benchmark | GD-1 | GD-2 | GD-4 | GD-8 |
|:----------|:-----|:-----|:-----|:-----|
| sload_benchmark | 9 runs | 9 runs | 9 runs | -- |
| sstore_variants | 9 runs | 9 runs | 9 runs | 4 runs |
| erc20_balanceof | 9 runs | 9 runs | 9 runs | 9 runs |
| erc20_approve | 9 runs | 9 runs | 9 runs | 9 runs |
| mixed_sload_sstore | 9 runs | 9 runs | 9 runs | 9 runs |

GD-8 synthetic benchmarks were not completed -- each configuration requires a full 360 GB database rebuild and multi-day benchmark run. ERC20 benchmarks have complete data for all four group depths.

## Results

**GD-4 is optimal.** Statistically identical read performance to GD-8 (3% difference, p=0.045 borderline) but **45% faster writes** (p < 1e-9).

The mechanism: each trie node at group depth *g* contains an internal binary subtree with 2^g - 1 nodes that must be rehashed on every write. GD-8 nodes have 255 internal nodes vs 15 for GD-4 -- a 17x per-node cost that overwhelms the 2x shorter traversal path.

| Criterion | GD-4 | GD-8 | Winner |
|:----------|:-----|:-----|:-------|
| Reads (ERC20) | 3,067 ms | 2,977 ms | GD-8 by 3% (p=0.045, borderline) |
| Writes (ERC20) | 678 ms | 982 ms | **GD-4 by 45%** (p < 1e-9) |
| Mixed | 2,302 ms | 2,145 ms | Indistinguishable (p=0.37) |

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
