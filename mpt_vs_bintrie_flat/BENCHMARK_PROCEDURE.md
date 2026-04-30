# Benchmarking Procedure: MPT vs Binary Trie (with Flat State)

This document describes the end-to-end procedure used to benchmark Ethereum's Merkle Patricia Trie (MPT) against the Binary Trie (EIP-7864) with and without flat state, using ERC20 workloads on geth.

## Overview

The benchmarking pipeline has four stages:

1. **Database generation** — state-actor creates a large state DB (~500GB–1.6TB)
2. **ERC20 deployment** — spamoor deploys a 2–5 GB ERC20 contract onto the DB
3. **Benchmark execution** — cold-cache benchmark runs using execution-specs
4. **Data extraction** — CSV extraction from geth slow-block logs

Each stage is automated via shell scripts. The entire pipeline takes 1–3 days per configuration depending on DB size and ERC20 bloat target.

---

## 1. Hardware & environment

| Component | Specification |
|:----------|:-------------|
| CPU | AMD EPYC 9454P 48-Core (96 threads) |
| RAM | 126 GB DDR5 |
| Storage | 3.5 TB SSD (md RAID) |
| OS | Ubuntu 24.04 LTS |
| Go | 1.24.1 |
| Python | 3.12 (via uv) |

## 2. Software components

| Tool | Version/Commit | Purpose |
|:-----|:---------------|:--------|
| [go-ethereum (MPT)](https://github.com/ethereum/go-ethereum) | `5d0e18f7` | Upstream geth for MPT benchmarks |
| [go-ethereum (bintrie)](https://github.com/CPerezz/go-ethereum) | `7d2e7cbe` (bintrie-flat-state branch) | Binary trie geth with flat state support |
| [state-actor](https://github.com/ethpandaops/state-actor) | PR#19 `5365b8f` + local fixes | Generates the state database (trie nodes + flat state stem blobs) |
| [spamoor](https://github.com/ethpandaops/spamoor) | latest | Deploys ERC20 contracts with configurable storage bloat |
| [execution-specs](https://github.com/ethereum/execution-specs) | latest | Benchmark test harness (pytest-based ERC20 workloads) |
| [uv](https://github.com/astral-sh/uv) | latest | Python package runner for execution-specs |

### Building binaries

```bash
# MPT geth
cd go-ethereum && git checkout master
go build -o bin/geth-mpt ./cmd/geth

# Bintrie geth (with flat state)
cd go-ethereum && git checkout bintrie-flat-state
go build -o bin/geth-bintrie ./cmd/geth

# State-actor (with flat state fixes)
cd state-actor
go build -o bin/state-actor-bintrie .

# fix_snap tool (snapshot metadata repair)
cd tools/fix_snap
go build -o bin/fix_snap .
```

## 3. Database generation

### 3.1 State-actor: generating the trie

State-actor creates a Pebble database containing:
- **Trie nodes** — grouped binary trie nodes (path `"v"` namespace) for root computation
- **Stem blobs** — packed flat-state blobs (key `"vX"` + 31-byte stem) for O(1) lookups
- **Genesis block** — with `EnableVerkleAtGenesis=true`, correct state root, and `DatabaseVersion=9`
- **Code entries** — contract bytecode at `"c"` + keccak256(code)

```bash
bin/state-actor-bintrie \
  -db dbs/bt-gd5-flat/geth/chaindata \
  -genesis genesis.json \
  -target-size 500GB \
  -contracts 100000 \
  -inject-accounts "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" \
  -seed 25519 \
  -binary-trie \
  -group-depth 5 \
  -benchmark \
  -verbose
```

| Parameter | Value | Notes |
|:----------|:------|:------|
| `-target-size` | 500GB (flat) / 1200GB (non-flat) | On-disk Pebble DB size target |
| `-contracts` | 100,000 | Capped; actual count may be lower based on target size |
| `-seed` | 25519 | Deterministic generation for reproducibility |
| `-group-depth` | 5 | Binary trie groups 5 levels per serialized node (2^5=32 children) |
| `-inject-accounts` | Anvil's default | Pre-funded with ~1B ETH |

**Phase 1** (entry generation): Creates all account/storage entries in a temporary Pebble DB, sorted by key. Takes ~1 hour for 500GB target.

**Phase 2** (trie building): Streams sorted entries through a binary stack trie builder. Computes sha256 root hash and writes grouped trie nodes + stem blobs to the final Pebble DB. Takes ~5 hours at ~90 GB/h.

**Output**: A Pebble DB with trie nodes, stem blobs, genesis block, and all metadata. The genesis state root is printed at the end (needed for `fix_snap`).

### 3.2 State-actor fixes for flat state

State-actor PR#19 wrote stem blobs correctly but had three metadata bugs. We applied local fixes:

1. **`WriteDatabaseVersion(9)`** — Without this, geth's `--dev` mode treats the DB as uninitialized and creates a fresh genesis, ignoring all state-actor data.

2. **`"v"` prefix on PathDB metadata** — `WriteStateID`, `WritePersistentStateID`, `WriteSnapshotRoot`, and `WriteSnapshotGenerator` must be written under the `"v"` prefix (geth's `rawdb.VerklePrefix`), because pathdb wraps diskdb with `rawdb.NewTable(diskdb, "v")` in bintrie mode.

3. **`IsBintrie=true` in SnapshotGenerator** — The `snapshotGenerator` RLP struct must have `IsBintrie: true`. Geth's `loadGenerator` checks `generator.IsBintrie != isBintrie` and discards mismatched markers.

### 3.3 MPT database generation

For the MPT baseline, state-actor runs without `-binary-trie`, producing a standard geth Pebble DB with MPT trie nodes and snapshot entries (`"a"` + hash for accounts, `"o"` + hash for storage).

```bash
bin/state-actor-mpt \
  -db dbs/mpt/geth/chaindata \
  -genesis genesis.json \
  -target-size 1200GB \
  -contracts 100000 \
  -inject-accounts "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" \
  -seed 25519
```

## 4. ERC20 deployment (spamoor)

After DB generation, we deploy a large ERC20 contract using spamoor's `erc20_bloater` scenario. This creates realistic storage access patterns for benchmarks.

### 4.1 Starting geth for deployment

```bash
bin/geth-bintrie \
  --datadir dbs/bt-gd5-flat \
  --dev --dev.period 1 --dev.gaslimit 1000000000 \
  --miner.etherbase 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --cache 4096 \
  --debug.logslowblock=0 \
  --http --http.addr 0.0.0.0 --http.port 8545 \
  --http.api eth,net,web3,debug,miner,txpool,admin \
  --nodiscover --maxpeers 0 \
  --rpc.allow-unprotected-txs --rpc.txfeecap 0 --rpc.gascap 0 \
  --verbosity 3 \
  --override.verkle=0 --bintrie.groupdepth 5
```

Key flags:
- `--dev.period 1` — fast block production for deployment (1 block/sec)
- `--dev.gaslimit 1000000000` — 1B gas limit target (ramps up gradually)
- `--cache 4096` — 4GB cache for fast deployment (NOT used during benchmarks)

### 4.2 Gas limit ramping

The gas limit starts at the genesis value and ramps toward the 1B target at ~1/1024 per block. We set the miner target and run a monitoring script that restarts spamoor at each 100M milestone:

```bash
# Set miner target to 1B
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"miner_setGasLimit","params":["0x3B9ACA00"],"id":1}'

# Run ramp monitor (restarts spamoor at 100M, 200M, ..., 900M)
bash scripts/spamoor_ramp_v2.sh
```

Each restart allows spamoor to discover the higher gas limit and send more transactions per round (3 txs at 60M → 44 txs at 1B).

### 4.3 Spamoor deployment

```bash
spamoor erc20_bloater \
  --rpchost=http://localhost:8545 \
  --privkey="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" \
  --seed=mpt-vs-bt \
  --target-gb=5 \
  --target-gas-ratio=0.8 \
  --wallet-count=200 \
  -v
```

| Parameter | Value | Notes |
|:----------|:------|:------|
| `--target-gb` | 5 | Total ERC20 storage to deploy |
| `--target-gas-ratio` | 0.8 | Use 80% of block gas limit per round |
| `--wallet-count` | 200 | Parallel wallets for tx construction |
| `--seed` | `mpt-vs-bt` | Deterministic wallet derivation |

Spamoor deploys one ERC20 contract and fills it with storage slots across ~84M addresses. Each round sends N transactions (N = gas_limit / 16.7M due to EIP-7825 gas cap), each writing 370 storage entries. At full gas (1B), deployment runs at ~180 MB/h.

**Resuming after interruption**: Use `--existing-contract=0x...` to skip contract re-deployment.

### 4.4 stubs.json

After deployment, create `stubs.json` mapping benchmark test names to the deployed contract address:

```json
{
  "test_sload_empty_erc20_balanceof_SMALL": "0xF852dB3A94Ee27370B47011eBD1610e7718802Bd",
  "test_sstore_erc20_approve_SMALL": "0xF852dB3A94Ee27370B47011eBD1610e7718802Bd",
  "test_mixed_sload_sstore_SMALL": "0xF852dB3A94Ee27370B47011eBD1610e7718802Bd"
}
```

## 5. Benchmark execution

### 5.1 Cold-cache protocol

Each benchmark run follows this protocol to ensure cold-cache measurements:

1. **Kill geth** (graceful SIGTERM, 60s timeout)
2. **Drop OS page cache**: `sync && echo 3 > /proc/sys/vm/drop_caches`
3. **Reset snapshot root** (bintrie only): `fix_snap <chaindata> <genesis-root>`
4. **Start geth** with `--cache 0` (no Pebble block cache)
5. **Wait for gas limit** ≥ 101M (polls every second, up to 600s)
6. **Execute benchmark** via execution-specs
7. **Save logs** (`{bench}_run{N}_geth.log`, `{bench}_run{N}_test.log`)

### 5.2 fix_snap: snapshot root consistency

With `--cache 0`, geth's pathdb never caps diff layers to the disk layer. The disk layer root stays at the genesis state root. On graceful shutdown, geth persists the HEAD root (which differs from the disk layer root) as `SnapshotRoot`. On the next start, geth detects the mismatch between disk layer root and `SnapshotRoot`, concluding the snapshot is inconsistent, and triggers a 24h+ full regeneration.

`fix_snap` resets `SnapshotRoot` and `SnapshotGenerator` to the genesis root before each geth start:

```bash
bin/fix_snap dbs/bt-gd5-flat/geth/chaindata \
  0xcc802d03e8fdd13339d515f801b3f88b23cd7782aa59ac62feab348d9c713c5f
```

This ensures geth accepts the existing flat state stem blobs without regeneration. The diff layers from previous blocks are replayed from the pathdb journal on startup.

### 5.3 Geth configuration for benchmarks

```bash
bin/geth-bintrie \
  --datadir dbs/bt-gd5-flat \
  --dev --dev.period 10 --dev.gaslimit 110000000 \
  --miner.etherbase 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --cache 0 \
  --debug.logslowblock=0 \
  --http --http.addr 0.0.0.0 --http.port 8545 \
  --http.api eth,net,web3,debug,miner,txpool,admin,personal \
  --nodiscover --maxpeers 0 \
  --rpc.allow-unprotected-txs --rpc.txfeecap 0 --rpc.gascap 0 \
  --verbosity 3 \
  --override.verkle=0 --bintrie.groupdepth 5
```

Key differences from deployment phase:
- `--cache 0` — truly cold Pebble reads
- `--dev.period 10` — 10s block time (benchmark txs need time to be submitted)
- `--debug.logslowblock=0` — log every block's timing/cache JSON (threshold=0ms)

### 5.4 Benchmark tests

Three ERC20 benchmarks test different access patterns:

| Benchmark | Test | Access | Fork | Tx structure |
|:----------|:-----|:-------|:-----|:-------------|
| `erc20_balanceof` | `test_sload_empty_erc20_balanceof` | Read-only (SLOAD) | Osaka | ~6 × 16.7M gas txs |
| `mixed_sload_sstore` | `test_mixed_sload_sstore` | 50/50 read+write | Osaka | ~6 × 16.7M gas txs |
| `erc20_approve` | `test_sstore_erc20_approve` | Write-heavy (SSTORE) | Osaka | ~6 × 16.7M gas txs |

For bintrie configs, `--fork Osaka` is used because the chain has `EnableVerkleAtGenesis=true`, which activates the Osaka fork (including EIP-7825's 16M per-transaction gas cap). The execution-specs test code splits the 100M gas benchmark into ~6 transactions of ~16.7M each.

For MPT, `--fork Prague` is used with `--override.osaka=4294967295` to disable EIP-7825 and allow single 100M gas transactions.

### 5.5 Running the campaign

```bash
# Run all 3 benchmarks × 10 runs for bt-gd5-flat
NUM_RUNS=10 CONFIGS="bt-gd5-flat" bash scripts/run_benchmarks.sh
```

The script runs benchmarks in order: `balanceof` → `mixed` → `approve` (read-only first, writes last to minimize mutation impact on subsequent runs).

## 6. Data extraction

### 6.1 Slow block JSON

Geth logs a JSON entry for every block with `--debug.logslowblock=0`:

```json
{
  "msg": "Slow block",
  "block": {"number": 123, "gas_used": 16700000, "tx_count": 1},
  "timing": {
    "execution_ms": 45.2,
    "state_read_ms": 530.1,
    "state_hash_ms": 2.8,
    "commit_ms": 17.3,
    "total_ms": 853.4
  },
  "throughput": {"mgas_per_sec": 19.5},
  "state_reads": {"accounts": 7, "storage_slots": 5095, "code": 1},
  "state_writes": {"accounts": 3, "storage_slots": 0},
  "cache": {
    "account": {"hits": 4, "misses": 3, "hit_rate": 57.1},
    "storage": {"hits": 3467, "misses": 1628, "hit_rate": 68.1},
    "code": {"hits": 1, "misses": 0, "hit_rate": 100.0}
  }
}
```

### 6.2 CSV extraction

```bash
# Per-config extraction
python3 scripts/extract_csv.py results/bt-gd5-flat \
  --config bt-gd5-flat \
  --trie-type bintrie \
  --group-depth 5 \
  --pebble-block-size-kb 4

# Consolidate all configs into one CSV
python3 scripts/extract_csv.py --consolidate \
  --consolidate-dir results --output-dir data
```

**Filtering**: Only blocks with `gas_used > 500,000` are included as benchmark blocks. Pre-allocation and empty blocks are excluded.

### 6.3 Output files

```
data/
├── mpt_vs_bintrie_consolidated.csv    # All configs merged
├── bt-gd5-flat_all_benchmarks.csv     # All benchmarks for flat config
├── bt-gd5-flat_erc20_balanceof.csv    # Per-benchmark
├── bt-gd5-flat_erc20_approve.csv
├── bt-gd5-flat_mixed_sload_sstore.csv
└── bt-gd5-flat_cache_validation.csv   # Per-run cache aggregates
```

## 7. Key metrics

| Metric | Source | What it measures |
|:-------|:-------|:-----------------|
| `total_ms` | Slow block JSON | Wall-clock block processing time |
| `state_read_ms` | Slow block JSON | Time spent reading state (flat state or trie traversal) |
| `state_hash_ms` | Slow block JSON | Time spent computing trie root hash |
| `execution_ms` | Slow block JSON | EVM execution time |
| `commit_ms` | Slow block JSON | Time flushing state changes to diff layer |
| `slots/s` | Computed | `(storage_slots_read + storage_slots_written) / (total_ms / 1000)` |
| `µs/slot (read)` | Computed | `(state_read_ms × 1000) / total_slots` |
| `storage_cache_hit_rate` | Slow block JSON | In-memory prefetcher cache hit rate (see CACHE_ANALYSIS.md) |

## 8. Important caveats

### EIP-7825 gas cap asymmetry

BT-GD5-flat runs with the Osaka fork (EIP-7825), which caps per-transaction gas at 16M. The 100M gas benchmark splits into ~6 transactions across 2-4 blocks. MPT and BT-GD5 (pre-Osaka) send a single 100M gas transaction per block.

This means BT-GD5-flat processes fewer slots per block (~5K–12K) vs MPT (~37K). The per-slot metrics (`slots/s`, `µs/slot`) normalize for this, but fixed per-block overhead (trie init, block building) is amortized over fewer slots in the flat config.

### Database size asymmetry

BT-GD5-flat (507 GB) is smaller than MPT (1.6 TB) and BT-GD5 (1.4 TB). Smaller databases have shallower Pebble LSM trees, reducing per-read latency. The flat state advantage is structural (O(1) vs O(depth)) and would hold at any size, but absolute numbers may be slightly optimistic.

### Cache hit rate asymmetry

BT-GD5-flat shows higher storage cache rates (68–84%) than MPT (7–15%). This is caused by the `stateReaderWithCache` prefetcher race (see `CACHE_ANALYSIS.md`), not by cross-run caching or setup error. The wall-clock `total_ms` and `state_read_ms` metrics already incorporate the prefetch benefit and are the authoritative performance numbers.

### Snapshot root reset

The `fix_snap` tool must be run before each benchmark geth start (bintrie only, when `--cache 0`). Without it, geth triggers a 24h+ snapshot regeneration and all reads fall through to the trie reader, negating flat state entirely. The benchmark script handles this automatically.

## 9. Reproducibility checklist

- [ ] Group depth matches between state-actor (`-group-depth 5`) and geth (`--bintrie.groupdepth 5`)
- [ ] Genesis state root from state-actor matches the root passed to `fix_snap`
- [ ] `stubs.json` contract address matches the deployed ERC20
- [ ] Private key matches between state-actor (`-inject-accounts`), spamoor (`--privkey`), and benchmarks (`RPC_SEED_KEY`)
- [ ] `--cache 0` for benchmark runs (not deployment)
- [ ] OS page cache dropped between runs (`echo 3 > /proc/sys/vm/drop_caches`)
- [ ] No snapshot regeneration in any geth log (grep for `"Generating bintrie"`)
- [ ] All benchmark blocks have gas > 500K in the CSVs
