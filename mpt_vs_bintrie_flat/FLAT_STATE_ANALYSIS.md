# Binary Trie Flat State Benchmarks: MPT vs BT-GD5 vs BT-GD5-flat

Performance comparison of Ethereum's Merkle Patricia Trie (MPT), Binary Trie without flat state (BT-GD5), and Binary Trie with flat state enabled (BT-GD5-flat) using ERC20 workloads on the geth implementation.

## Key finding

**Flat state eliminates the state-read bottleneck for binary trie.** Read latency drops from 216–364 µs/slot (trie traversal) to 35–55 µs/slot (direct stem blob lookup), making bintrie **1.8–2.4× faster than MPT** for read-heavy workloads — bringing bintrie's reads to parity with MPT, whose SLOADs are already served by its flat snapshot in ~1 read (the multiple is parity-plus, driven by flat's 3× smaller DB and the prefetcher race; see the report's §S3/§S6). The remaining bottleneck is `trie_updates` (trie root recomputation), which dominates write-heavy benchmarks.

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
| **erc20_balanceof** | 6,980 | 4,128 | **12,486** | **1.8× faster** | **3.0× faster** |
| **mixed_sload_sstore** | 6,987 | 1,991 | **16,520** | **2.4× faster** | **8.3× faster** |
| **erc20_approve** | 8,715 | 1,757 | **3,555** | 0.4× (slower) | **2.0× faster** |

### Read latency: µs per slot (lower = better)

| Benchmark | MPT | BT-GD5 | BT-GD5-flat | flat vs MPT | flat vs BT-GD5 |
|:----------|:----|:-------|:------------|:------------|:---------------|
| **erc20_balanceof** | 135 | 216 | **55** | **2.5× faster** | **3.9× faster** |
| **mixed_sload_sstore** | 135 | 334 | **35** | **3.8× faster** | **9.5× faster** |
| **erc20_approve** | 139 | 364 | **46** | **3.0× faster** | **7.9× faster** |

### Timing breakdown (median per block, milliseconds)

| Benchmark | Config | total_ms | state_read | trie_updates | execution | commit | slots/block |
|:----------|:-------|:---------|:-----------|:-----------|:----------|:-------|:------------|
| erc20_balanceof | MPT | 5,264 | 4,956 (94%) | 0 | 282 | 28 | 36,742 |
| | BT-GD5 | 8,901 | 7,935 (89%) | 0 | 964 | 25 | 36,741 |
| | **BT-GD5-flat** | **658** | **469 (71%)** | 2 | 182 | 9 | 6,114 |
| mixed_sload_sstore | MPT | 3,352 | 3,151 (94%) | 0 | 181 | 18 | 23,418 |
| | BT-GD5 | 3,470 | 2,302 (66%) | 412 | 65 | 56 | 5,556 |
| | **BT-GD5-flat** | **660** | **372 (56%)** | 3 | 265 | 10 | 11,691 |
| erc20_approve | MPT | 939 | 570 (61%) | 288 | 45 | 31 | 8,188 |
| | BT-GD5 | 2,000 | 1,064 (53%) | 738 | 66 | 65 | 4,094 |
| | **BT-GD5-flat** | **1,030** | **83 (8%)** | **829 (81%)** | 68 | 6 | 4,086 |

### Storage cache hit rates

| Benchmark | MPT | BT-GD5 | BT-GD5-flat |
|:----------|:----|:-------|:------------|
| erc20_balanceof | 6.9% | 35.0% | 11.3% |
| mixed_sload_sstore | 9.5% | 72.3% | 42.0% |
| erc20_approve | 14.8% | 72.9% | 41.4% |

These are **median per-block** rates; note BT-GD5, not flat, shows the highest medians. (Pooled `hits/(hits+misses)` run higher — ~70–85% for flat — because a few large warm blocks dominate the pool.) See [`CACHE_ANALYSIS.md`](CACHE_ANALYSIS.md) for the root cause: the `stateReaderWithCache` prefetcher race lifts all bintrie configs above MPT. It does **not** invalidate the wall-clock `total_ms` and `state_read_ms` metrics, which are the authoritative performance numbers.

## Analysis

### Where flat state wins: reads (balanceof, mixed)

Flat state transforms bintrie reads from O(depth) trie traversals to O(1) stem blob lookups:

- **Without flat state**: each SLOAD traverses the binary trie (logical path ~248 bits ≈ 50 group nodes per stem at groupDepth=5). Upper group nodes amortize in-memory within a block, so the marginal cost is a few node reads rather than the full ~50. Result: **216 µs/slot** (median).
- **With flat state**: each SLOAD is a single Pebble read of the stem blob at `"vX" + stem(31 bytes)`, followed by a bitmap + offset extraction. Result: **55 µs/slot** (median).

This **3.9× read speedup over non-flat BT-GD5** is the structural win: flat state removes bintrie's traversal penalty. The comparison **to MPT** is subtler — MPT's SLOADs are *also* served by its flat snapshot in ~1 read, and per cold disk read the two are statistically indistinguishable (`ms_per_cache_miss` ≈ 135–146 µs for both on balanceof). So flat-vs-MPT (2.5×) is not a "fewer reads" effect; it comes from flat taking fewer disk trips per slot (blob packing + prefetcher race) on a 3× smaller LSM. At equal DB size the two would be close to parity (see "Database size caveat" below).

### Where flat state doesn't help: writes (approve)

For approve (SSTORE), flat state eliminates the read latency (83ms vs 1,064ms median), but the bottleneck shifts to `trie_updates`:

| Phase | BT-GD5 | BT-GD5-flat | Change |
|:------|:-------|:------------|:-------|
| state_read | 1,064 ms (53%) | 83 ms (8%) | **12.8× faster** |
| trie_updates | 738 ms (37%) | 829 ms (81%) | 1.1× slower |
| total | 2,000 ms | 1,030 ms | **1.9× faster** |

Root recomputation needs the **intermediate** nodes along every modified path — and those are not in the flat layer, so they are read (cold) from the trie and rehashed. The binary trie is far deeper than MPT's hex trie (~248 bit-levels, ≈50 group nodes per stem vs ~5–7 hex levels), so each modified slot pulls roughly an order of magnitude more intermediate nodes through the read-and-hash path. This is inherent to the binary trie structure and unaffected by flat state.

MPT's `trie_updates` is only 288ms because its hex trie is shallower; per slot written, bintrie-flat's hashing cost is **~6.75× MPT's** (bootstrap CI 6.3–7.4×). (Note: BT-GD5's `storage_slots_written` counter reads 0 on approve despite the 738 ms it spends hashing — the counter is unreliable on the bintrie binaries, so per-slot write rates for BT-GD5 are derived from reads.)

### Slots per block asymmetry

BT-GD5-flat processes fewer slots per block than MPT for balanceof (median 6,114 vs 36,742) because EIP-7825 (Osaka fork) caps per-transaction gas at 16M. The benchmark splits the 100M gas target into ~6 transactions, which may land across 2-3 blocks depending on timing. MPT and BT-GD5 (pre-Osaka) send a single 100M gas transaction per block.

This asymmetry is why per-block totals are not comparable across configs; use the per-slot metrics (`slots/s`, `µs/slot`), which normalize by actual slot count. The `total_ms` per block is lower for BT-GD5-flat (658ms vs 5,264ms) largely because each block processes fewer slots; the `µs/slot` read-latency metric (55 vs 135 median) is the comparable figure. The multi-tx shape also feeds the `stateReaderWithCache` prefetcher race, which is part of why flat's per-slot read latency beats MPT's (see the report's §S3).

### Database size caveat

The BT-GD5-flat database (507 GB) is smaller than MPT (1.6 TB) and BT-GD5 (1.4 TB) because:
1. Flat state stem blobs are more compact than MPT snapshot entries
2. The ERC20 bloat was stopped at ~2.0 GB (vs ~2.5-2.8 GB for the other configs)
3. State-actor generated fewer total entries for the 500 GB target

A smaller database is *expected* to mean shorter Pebble LSM lookups — though in this campaign the measured per-cold-read latency (`ms_per_cache_miss`) is actually equal-or-higher for BT-GD5-flat than MPT, so the size effect shows up via the cache/prefetch path rather than cheaper individual reads. The flat-state advantage *over non-flat bintrie* (removing trie traversal) is structural and holds at any size; the advantage *over MPT* is largely the ~3× size gap plus the prefetcher race, so the absolute µs/slot numbers for BT-GD5-flat are optimistic, and an equally-sized re-run is the key follow-up.

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
