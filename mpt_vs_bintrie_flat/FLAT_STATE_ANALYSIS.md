# Binary Trie Flat State Benchmarks: MPT vs BT-GD5 vs BT-GD5-flat

Performance comparison of Ethereum's Merkle Patricia Trie (MPT), Binary Trie without flat state (BT-GD5), and Binary Trie with flat state enabled (BT-GD5-flat) using ERC20 workloads on the geth implementation.

## Key finding

**Flat state eliminates the state-read bottleneck for binary trie.** Read latency drops from 255–334 µs/slot (trie traversal) to 23–45 µs/slot (direct stem blob lookup), making bintrie **2.0–2.3× faster than MPT** for read-heavy workloads. The remaining bottleneck is `state_hash` (trie root recomputation), which dominates write-heavy benchmarks.

## Campaign

| Parameter | Value |
|:----------|:------|
| Machine | Bare metal — AMD EPYC 9454P 48-Core (96 threads), 126 GB RAM, 3.5 TB SSD (md RAID), Ubuntu 24.04 LTS |
| Databases | MPT: 1.6 TB, ~2.53 GB ERC20 bloat; BT-GD5: 1.4 TB, ~2.76 GB ERC20 bloat; BT-GD5-flat: 507 GB, ~2.0 GB ERC20 bloat |
| Configurations | `mpt` (upstream geth master), `bt-gd5` (bintrie fork, groupDepth=5, no flat state), `bt-gd5-flat` (bintrie fork, groupDepth=5, flat state enabled) |
| Protocol | Cold cache (OS page cache dropped + Pebble cache=0 between runs) |
| Gas target | 100M gas per block (MPT/BT-GD5: single tx; BT-GD5-flat: ~6×16.7M txs via EIP-7825) |
| ERC20 contract | `0xF852dB3A94Ee27370B47011eBD1610e7718802Bd` (all configs) |
| Seed account | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` (~1B ETH) |

### Geth binaries

| Binary | Source | Commit | Built |
|:-------|:-------|:-------|:------|
| `geth-mpt` | go-ethereum master | `5d0e18f7` | 2026-03-25 |
| `geth-bintrie` (BT-GD5) | go-ethereum bintrie fork | `991300c4` | 2026-03-19 |
| `geth-bintrie` (BT-GD5-flat) | go-ethereum bintrie-flat-state | `7d2e7cbe` | 2026-04-27 |

### State-actor

| Binary | Source | Commit | Notes |
|:-------|:-------|:-------|:------|
| `state-actor-bintrie` | state-actor PR#19 + local fixes | `5365b8f` + local | Fixed: `v`-prefix metadata, `WriteDatabaseVersion`, `isBintrie=true` in SnapshotGenerator |

### Benchmarks

| Benchmark | Type | Access pattern | Measures |
|:----------|:-----|:---------------|:---------|
| erc20_balanceof | ERC20 | Random (keccak-hashed) | Read-only contract calls (SLOAD) |
| erc20_approve | ERC20 | Random (keccak-hashed) | Write contract calls (SSTORE) |
| mixed_sload_sstore | Mixed | Random | Interleaved 50-50 reads + writes |

### Data completeness

| Benchmark | MPT | BT-GD5 | BT-GD5-flat |
|:----------|:----|:-------|:------------|
| erc20_balanceof | 100 runs (100 blocks) | 10 runs (10 blocks) | 10 runs (31 blocks) |
| erc20_approve | 100 runs (100 blocks) | 10 runs (27 blocks) | 10 runs (20 blocks) |
| mixed_sload_sstore | 100 runs (100 blocks) | 10 runs (22 blocks) | 10 runs (20 blocks) |

BT-GD5-flat produces multiple blocks per run due to EIP-7825's 16M per-transaction gas cap (Osaka fork), which splits the 100M gas benchmark into ~6 transactions across multiple blocks.

## Results

### Throughput: slots per second (higher = better)

| Benchmark | MPT | BT-GD5 | BT-GD5-flat | flat vs MPT | flat vs BT-GD5 |
|:----------|:----|:-------|:------------|:------------|:---------------|
| **erc20_balanceof** | 6,958 | 3,460 | **13,873** | **2.0× faster** | **4.0× faster** |
| **mixed_sload_sstore** | 6,993 | 2,762 | **16,040** | **2.3× faster** | **5.8× faster** |
| **erc20_approve** | 8,741 | 1,790 | **3,494** | 0.4× (slower) | **2.0× faster** |

### Read latency: µs per slot (lower = better)

| Benchmark | MPT | BT-GD5 | BT-GD5-flat | flat vs MPT | flat vs BT-GD5 |
|:----------|:----|:-------|:------------|:------------|:---------------|
| **erc20_balanceof** | 135.3 | 255.4 | **44.8** | **3.0× faster** | **5.7× faster** |
| **mixed_sload_sstore** | 134.5 | 287.2 | **36.0** | **3.7× faster** | **8.0× faster** |
| **erc20_approve** | 69.4 | 334.2 | **22.7** | **3.1× faster** | **14.7× faster** |

### Timing breakdown (avg per block, milliseconds)

| Benchmark | Config | total_ms | state_read | state_hash | execution | commit | slots/block |
|:----------|:-------|:---------|:-----------|:-----------|:----------|:-------|:------------|
| erc20_balanceof | MPT | 5,280 | 4,971 (94%) | 0 | 280 | 29 | 36,742 |
| | BT-GD5 | 10,620 | 9,384 (88%) | 0 | 1,207 | 28 | 36,741 |
| | **BT-GD5-flat** | **853** | **530 (62%)** | 3 | 303 | 17 | 11,834 |
| mixed_sload_sstore | MPT | 3,349 | 3,149 (94%) | 0 | 180 | 19 | 23,418 |
| | BT-GD5 | 4,638 | 3,679 (79%) | 508 | 389 | 62 | 12,812 |
| | **BT-GD5-flat** | **729** | **421 (58%)** | 4 | 287 | 16 | 11,691 |
| erc20_approve | MPT | 937 | 568 (61%) | 289 | 46 | 33 | 8,188 |
| | BT-GD5 | 2,242 | 1,341 (60%) | 745 | 86 | 69 | 4,014 |
| | **BT-GD5-flat** | **1,169** | **93 (8%)** | **988 (85%)** | 79 | 9 | 4,086 |

### Storage cache hit rates

| Benchmark | MPT | BT-GD5 | BT-GD5-flat |
|:----------|:----|:-------|:------------|
| erc20_balanceof | 7.1% | 38.5% | 68.1% |
| mixed_sload_sstore | 9.0% | 44.8% | 84.5% |
| erc20_approve | 14.5% | 64.6% | 83.8% |

See [`CACHE_ANALYSIS.md`](CACHE_ANALYSIS.md) for why bintrie configs show higher cache hit rates. The root cause is the `stateReaderWithCache` prefetcher race: when reads are faster (flat state), the prefetcher wins the race more often. This inflates the cache rate further for BT-GD5-flat but does **not** invalidate the wall-clock `total_ms` and `state_read_ms` metrics, which are the authoritative performance numbers.

## Analysis

### Where flat state wins: reads (balanceof, mixed)

Flat state transforms bintrie reads from O(depth) trie traversals to O(1) stem blob lookups:

- **Without flat state**: each SLOAD requires traversing ~50 binary trie group nodes (31 bytes × 8 bits / groupDepth=5 ≈ 50 node reads). With `--cache 0` and cold OS cache, each node read is a Pebble disk lookup. Result: **255 µs/slot**.
- **With flat state**: each SLOAD is a single Pebble read of the stem blob at `"vX" + stem(31 bytes)`, followed by a bitmap + offset extraction. Result: **45 µs/slot**.

This **5.7× read speedup** (cold cache) makes bintrie-flat **2× faster than MPT** for read-heavy workloads, because MPT's read path also requires multiple trie node traversals (~5 branch nodes per path at ~135 µs/slot).

### Where flat state doesn't help: writes (approve)

For approve (SSTORE), flat state eliminates the read latency (93ms vs 1,341ms), but the bottleneck shifts to `state_hash`:

| Phase | BT-GD5 | BT-GD5-flat | Change |
|:------|:-------|:------------|:-------|
| state_read | 1,341 ms (60%) | 93 ms (8%) | **14.4× faster** |
| state_hash | 745 ms (33%) | 988 ms (85%) | 1.3× slower |
| total | 2,242 ms | 1,169 ms | **1.9× faster** |

The `state_hash` increase (745 → 988ms) is because BT-GD5-flat processes slightly more slots per block (4,086 vs 4,014), and the trie root recomputation involves rehashing all modified nodes from leaf to root. This is inherent to the binary trie structure and unaffected by flat state.

MPT's `state_hash` is only 289ms because MPT's hex trie is shallower (~5 levels vs ~50 for binary trie), requiring fewer hash computations per write.

### Slots per block asymmetry

BT-GD5-flat processes fewer slots per block than MPT for balanceof (11,834 vs 36,742) because EIP-7825 (Osaka fork) caps per-transaction gas at 16M. The benchmark splits the 100M gas target into ~6 transactions, which may land across 2-3 blocks depending on timing. MPT and BT-GD5 (pre-Osaka) send a single 100M gas transaction per block.

This asymmetry does **not** affect the per-slot metrics (`slots/s`, `µs/slot`) because those normalize by actual slot count. The `total_ms` per block is lower for BT-GD5-flat (853ms vs 5,280ms) partly because each block processes fewer slots, but the `µs/slot` metric (44.8 vs 135.3) confirms the improvement is real and not an artifact of smaller blocks.

### Database size caveat

The BT-GD5-flat database (507 GB) is smaller than MPT (1.6 TB) and BT-GD5 (1.4 TB) because:
1. Flat state stem blobs are more compact than MPT snapshot entries
2. The ERC20 bloat was stopped at ~2.0 GB (vs ~2.5-2.8 GB for the other configs)
3. State-actor generated fewer total entries for the 500 GB target

A smaller database means shorter Pebble LSM-tree lookups, which benefits all read paths equally. The flat state advantage (O(1) vs O(depth)) is structural and would hold at any database size, but the absolute µs/slot numbers for BT-GD5-flat may be slightly optimistic compared to an equally-sized database.

## Flat state architecture

### How flat state works

State-actor writes two data structures to Pebble:

1. **Trie nodes** (path `"v"` namespace): grouped binary trie nodes for root computation and state proofs
2. **Stem blobs** (key `"vX"` + stem): packed (bitmap, values) blobs for O(1) lookups

When geth processes a block:
- **Reads** (SLOAD) go through `bintrieFlatReader.Storage()` → single Pebble read of the stem blob → bitmap extraction → O(1)
- **Writes** (SSTORE) go through the trie path → modify nodes → recompute root hash → `CollectNodes` → update stem blobs in diff layer

### What was fixed

State-actor PR#19 wrote stem blobs correctly (`"vX"` prefix) but had three metadata bugs that prevented geth from using them:

1. **Missing `WriteDatabaseVersion(9)`**: geth treated the DB as uninitialized and created a fresh dev genesis on startup, ignoring all state-actor data.
2. **Missing `"v"` prefix on PathDB metadata**: `WriteStateID`, `WritePersistentStateID`, `WriteSnapshotRoot` were written without the `"v"` prefix that pathdb expects in bintrie mode.
3. **`isBintrie=false` in SnapshotGenerator**: the marker was written with `IsBintrie: false`, causing geth to discard it as a mismatch on bintrie databases.

Additionally, the benchmark script (`run_benchmarks.sh`) needed to reset the `SnapshotRoot` to the disk layer root before each geth restart, because `--cache 0` prevents diff layer capping and graceful shutdown persists the HEAD root (which differs from the disk layer root).

## Reproducing

### Additional prerequisites (beyond the original README)

| Tool | Purpose |
|:-----|:--------|
| `fix_snap` | Resets `SnapshotRoot` and `SnapshotGenerator` in Pebble (required before each benchmark run with `--cache 0`) |

### Running BT-GD5-flat benchmarks

```bash
# 1. Generate 500GB DB with flat state
bin/state-actor-bintrie \
  -db dbs/bt-gd5-flat/geth/chaindata \
  -genesis genesis.json \
  -target-size 500GB \
  -contracts 100000 \
  -inject-accounts "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266" \
  -seed 25519 \
  -binary-trie \
  -group-depth 5

# 2. Deploy ERC20 via spamoor (start geth first)
bin/geth-bintrie --datadir dbs/bt-gd5-flat \
  --dev --dev.period 1 --dev.gaslimit 1000000000 \
  --override.verkle=0 --bintrie.groupdepth 5 --cache 4096

spamoor erc20_bloater --target-gb=5 --target-gas-ratio=0.8 \
  --wallet-count=200 --seed=mpt-vs-bt

# 3. Before benchmarks: reset snapshot root to genesis root
bin/fix_snap dbs/bt-gd5-flat/geth/chaindata <genesis-state-root>

# 4. Run benchmarks
NUM_RUNS=10 CONFIGS=bt-gd5-flat bash scripts/run_benchmarks.sh
```

### Important: snapshot root consistency

With `--cache 0` (used for cold-cache benchmarks), pathdb never caps diff layers to disk. The disk layer root stays at the genesis root. On graceful shutdown, geth persists the HEAD root as `SnapshotRoot`, creating a mismatch on next startup that triggers a 24h+ snapshot regeneration.

The `run_benchmarks.sh` script calls `fix_snap` before each geth start to reset `SnapshotRoot` back to the disk layer root, preventing this issue.
