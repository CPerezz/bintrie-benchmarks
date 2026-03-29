# MPT vs Binary Trie Benchmarks

Performance comparison of Ethereum's Merkle Patricia Trie (MPT) against Binary Trie (group depth 5) using ERC20 workloads on the geth implementation.

[Full report](index.html) ·
[ethresear.ch post](ethresearch-post.md) ·
[Raw data](data/)

## Campaign

| Parameter | Value |
|:----------|:------|
| Machine | Bare metal -- AMD EPYC 9454P 48-Core (96 threads), 126 GB RAM, 3.5 TB SSD (md RAID), Ubuntu 24.04 LTS |
| Databases | MPT: 1.6 TB, ~2.53 GB ERC20 bloat; BT-GD5: 1.4 TB, ~2.76 GB ERC20 bloat |
| Configurations | `mpt` (upstream geth master), `bt-gd5` (bintrie fork, groupDepth=5) |
| Protocol | Cold cache (OS page cache dropped + Pebble cache=0 between runs) |
| Gas target | 100M gas per block |
| ERC20 contract | `0xF852dB3A94Ee27370B47011eBD1610e7718802Bd` (MPT), deployed via spamoor |
| Seed account | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (~1B ETH) |

### Geth binaries

| Binary | Source | Commit | Built |
|:-------|:-------|:-------|:------|
| `geth-mpt` | go-ethereum master | `5d0e18f7` | 2026-03-25 |
| `geth-bintrie` | go-ethereum bintrie fork | `991300c4` | 2026-03-19 |

### Benchmarks

| Benchmark | Type | Access pattern | Measures |
|:----------|:-----|:---------------|:---------|
| erc20_balanceof | ERC20 | Random (keccak-hashed) | Read-only contract calls (SLOAD) |
| erc20_approve | ERC20 | Random (keccak-hashed) | Write contract calls (SSTORE) |
| mixed_sload_sstore | Mixed | Random | Interleaved 50-50 reads + writes |

### Data completeness

| Benchmark | MPT | BT-GD5 |
|:----------|:----|:-------|
| erc20_balanceof | 100 runs | 10 runs |
| erc20_approve | 100 runs | 10 runs |
| mixed_sload_sstore | 100 runs | 10 runs |

MPT was benchmarked with 100 cold-cache runs per benchmark (300 total). BT-GD5 was benchmarked with 10 cold-cache runs per benchmark (30 total), reusing data from an earlier campaign.

### Raw results (all runs, benchmark blocks only, gas > 500K)

| Benchmark | Config | Runs | Avg total_ms | Avg Mgas/s | Avg storage cache |
|:----------|:-------|:-----|:-------------|:-----------|:------------------|
| erc20_balanceof | MPT | 100 | 5,280 ms | 18.96 | 7.1% |
| erc20_balanceof | BT-GD5 | 10 | 10,620 ms | 9.74 | 38.5% |
| erc20_approve | MPT | 100 | 937 ms | 100.29 | 14.5% |
| erc20_approve | BT-GD5 | 27 | 2,242 ms | 11.19 | 63.6% |
| mixed_sload_sstore | MPT | 100 | 3,349 ms | 29.87 | 9.0% |
| mixed_sload_sstore | BT-GD5 | 22 | 4,638 ms | 10.11 | 60.9% |

**Note on cache hit rates**: BT-GD5 storage cache rates are significantly higher (39-64%) than MPT (7-15%), meaning the bintrie runs had more warm cache. This makes direct comparison non-trivial -- the bintrie numbers may look better than they would under perfectly cold conditions.

## Contents

- [`CACHE_ANALYSIS.md`](CACHE_ANALYSIS.md) -- Deep analysis of the cache hit rate asymmetry between configs
- [`data/`](data/) -- Raw benchmark CSVs (per-block metrics for all runs)
- [`graphs/`](graphs/) -- Data visualizations (to be generated)
- [`logs/`](logs/) -- Raw geth logs per configuration
- [`scripts/`](scripts/) -- Automation scripts for the benchmark campaign:
  - `generate_db.sh` -- Generate 1TB+ state DBs with state-actor + deploy ERC20 via spamoor
  - `run_benchmarks.sh` -- Run ERC20 benchmarks with cold-cache protocol via execution-specs
  - `extract_csv.py` -- Parse geth slow-block JSON logs into per-benchmark and consolidated CSVs

## Procedure

### Database generation

Both DBs were generated using `state-actor` (100K contracts, seed 25519) to produce ~1TB+ state, then `spamoor erc20_bloater` deployed an ERC20 contract with ~2.5-2.8 GB of storage slots. The MPT DB was created using `geth-mpt` (upstream master) and the BT-GD5 DB using `geth-bintrie` with `--bintrie.groupdepth 5`.

```bash
# Generate both DBs (sequential, ~24h each)
bash scripts/generate_db.sh
```

### Gas limit ramp (MPT only)

The MPT chain's gas limit was stuck at 60M (from the deployment phase which used `--dev.gaslimit 100000000`). Before benchmarking, we ramped it to 110M:

1. Started geth-mpt with `--dev.period 1 --dev.gaslimit 110000000`
2. Called `miner_setGasLimit("0x68E7780")` to target 110M
3. Waited ~7 minutes (420 blocks at 1/1024 increase per block)
4. Gracefully stopped geth (gas limit persists in the chain)

### EIP-7825 workaround (MPT only)

The `geth-mpt` binary (upstream master, March 25) includes EIP-7825 (Osaka fork), which caps individual transaction gas at 16M (`params.MaxTxGas = 1 << 24`). Since the dev chain was created with `OsakaTime: 0` (Osaka enabled at genesis), 100M gas benchmark transactions were rejected.

**Fix**: Added `--override.osaka=4294967295` to push Osaka activation to year 2106, disabling EIP-7825's gas cap.

The BT-GD5 chain was created with an older geth that didn't store `osakaTime` in the genesis, so it was unaffected.

### Running benchmarks

```bash
# MPT: 100 runs per benchmark
CONFIGS=mpt NUM_RUNS=100 bash scripts/run_benchmarks.sh

# BT-GD5: 10 runs per benchmark (ran in prior campaign)
CONFIGS=bt-gd5 NUM_RUNS=10 bash scripts/run_benchmarks.sh
```

Each run:
1. Kill geth, `sync && echo 3 > /proc/sys/vm/drop_caches`
2. Start geth with `--cache 0 --dev.period 10 --dev.gaslimit 110000000`
3. Wait for gas limit >= 101M and RPC ready
4. Run benchmark via `uv run execute remote` (execution-specs)
5. Save geth log (contains `"Slow block"` JSON with timing/cache metrics)

### CSV extraction

```bash
# Per-config extraction
NUM_RUNS=100 python3 scripts/extract_csv.py results/mpt \
  --config mpt --trie-type mpt --group-depth 0 --pebble-block-size-kb 4

NUM_RUNS=10 python3 scripts/extract_csv.py results/bt-gd5 \
  --config bt-gd5 --trie-type bintrie --group-depth 5 --pebble-block-size-kb 4

# Consolidation
python3 scripts/extract_csv.py --consolidate \
  --consolidate-dir results --output-dir data
```

**Note**: `extract_csv.py` uses `NUM_RUNS` env var (default 10) to control how many runs to scan.

## Reproducing

### Prerequisites

| Tool | Purpose |
|:-----|:--------|
| [state-actor](https://github.com/ethpandaops/state-actor) | Generates the 1TB+ state databases |
| [geth (master)](https://github.com/ethereum/go-ethereum) | Upstream geth for MPT benchmarks |
| [geth (bintrie branch)](https://github.com/gballet/go-ethereum) | Binary trie-enabled geth fork |
| [spamoor](https://github.com/ethpandaops/spamoor) | Deploys ERC20 contracts onto the generated DBs |
| [execution-specs](https://github.com/ethereum/execution-specs) | Benchmark test harness (pytest-based) |
| [uv](https://github.com/astral-sh/uv) | Python package runner used by execution-specs |

### Important warnings

**Group depth must match between state-actor and geth.** When geth opens a bintrie database, `--bintrie.groupdepth` must be set to the same value used by state-actor when generating that DB. Using a different value **will corrupt the database irreversibly**.

**EIP-7825 (Osaka)**: If your geth binary includes Osaka and the dev chain was created with `OsakaTime: 0`, you must add `--override.osaka=4294967295` to allow 100M gas transactions.

**Spamoor's private key must match state-actor's injected account.** The `--privkey` passed to spamoor must correspond to the account given to state-actor's `-inject-accounts` flag. The scripts default to Anvil's well-known key (`0xac09...ff80`).

**kill_geth timeout**: The `run_benchmarks.sh` kill_geth function waits up to 60s for graceful shutdown before SIGKILL. With 1.6TB databases, geth needs time to flush pebble state. A premature SIGKILL can corrupt the DB.
