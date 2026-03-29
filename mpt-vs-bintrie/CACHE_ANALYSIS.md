# Cache Hit Rate Asymmetry: Bintrie (39-64%) vs MPT (7-15%)

The "Slow block" JSON logs show storage cache hit rates of 39-64% for bintrie vs 7-15% for MPT, despite both using the same cold-cache protocol (`--cache 0`, OS page cache dropped between every run). This document explains the root cause.

## What the "storage cache" actually measures

The storage cache hits/misses in "Slow block" logs measure **`stateReaderWithCache`** (`core/state/reader.go`, lines 354-460) — a per-block, in-memory `map[address][slot] -> value` cache. This is NOT a trie node cache, NOT the Pebble block cache, and NOT the trie clean/dirty cache.

This cache is **shared between two goroutines**:
- The **state prefetcher** goroutine, which re-executes transactions speculatively on separate CPU cores
- The **main block processor**, which executes transactions sequentially

The setup happens at `core/blockchain.go` line 2134:
```go
prefetch, process, err := sdb.ReadersWithCacheStats(parentRoot)
```

Both readers wrap the same `stateReaderWithCache` instance (`core/state/database.go` lines 226-234). The "Slow block" log reports the **main processor's** stats only.

### How a "cache hit" occurs

1. Prefetcher goroutine calls `reader.Storage(addr, slot)` → resolves from trie → inserts into shared map
2. Main processor later calls `reader.Storage(addr, slot)` → finds it in the map → **cache hit**

The hit rate is a function of a **concurrency race**: how far ahead the prefetcher can get before the main processor needs each slot.

## Why bintrie has higher cache hit rates

### Factor 1: Bintrie is slower per slot (dominant for balanceof)

Bintrie resolves storage slots ~2x slower than MPT due to deeper trie traversals:
- MPT: ~0.13 ms/slot for balanceof (hex trie, ~5 branch nodes per path)
- Bintrie: ~0.27 ms/slot for balanceof (binary trie with groupDepth=5, deeper paths)

When the main executor is slower per read, the prefetcher goroutine has **more wall-clock time to race ahead** and warm the cache before the main processor needs each slot. With MPT's faster reads, the main executor keeps pace with the prefetcher, yielding only ~6-7% hits.

Evidence (single-transaction blocks, balanceof):
| Config | Slots/block | state_read_ms | Hit rate |
|--------|------------|--------------|----------|
| MPT | 36,742 | 4,705 ms | 7.1% |
| BT-GD5 | 36,741 | 10,082 ms | 38.5% |

Same slot count, same benchmark, but 2x slower → 5x higher cache hit rate.

### Factor 2: Multi-transaction block bundling (dominant for approve)

With `--dev.period=10`, transactions submitted during benchmark execution accumulate in the mempool. Because bintrie processes blocks more slowly, more benchmark transactions arrive before the current block finalizes, causing the **next block to contain multiple transactions**.

With multiple txs per block, the prefetcher can process tx2, tx3, etc. while the main executor is still on tx1. By the time the main executor reaches later transactions, their slots are already cached.

Evidence from bt-gd5 approve data:
| Block type | Avg txs/block | Storage hit rate |
|-----------|--------------|-----------------|
| Multi-tx blocks (bintrie) | ~6.8 | **82.8%** |
| Single-tx blocks (bintrie) | ~1.0 | **34.8%** |
| Single-tx blocks (MPT) | ~1.0 | **14.5%** |

The highest cache rates in the bintrie data come from blocks with 5-10 transactions bundled together.

### Factor 3: Unified trie architecture

In bintrie, `IsVerkle()` returns true, so all storage reads go through a **single main trie** (`core/state/reader.go` line 262-263). In MPT, each account has a separate `StorageTrie` that must be opened individually (line 279). The unified trie makes the prefetcher more effective at warming the shared cache because both goroutines operate on the same trie structure without per-account overhead.

## What `--cache 0` does and doesn't disable

With `--cache 0` (`cmd/utils/flags.go` lines 1784-1860):
- **Disabled**: Pebble block cache, trie clean cache (pathdb/hashdb), trie dirty cache, snapshot cache
- **NOT disabled**: `stateReaderWithCache` — this is always active when prefetching is enabled (the default). It would only be disabled by `--cache.noprefetch`

The `stateObject.originStorage` map (`core/state/state_object.go` line 188) also caches resolved slots within the StateDB layer. Reads that hit `originStorage` never reach the reader layer, so they don't register as either hits or misses in the "Slow block" counters.

## What this is NOT

- **Not a setup error**: Both configs used identical cold-cache protocol
- **Not cross-run caching**: The shared cache is per-block; it dies when geth restarts between runs
- **Not trie node sharing**: The cache operates at `(address, slot)` granularity, not trie node level. Shared prefixes in the binary trie don't cause additional cache hits here
- **Not a bintrie-specific cache**: Both MPT and bintrie use the identical `stateReaderWithCache` code path

## Implications for comparison

1. **Cache hit rates are not directly comparable** between MPT and bintrie. The higher bintrie rate is an artifact of slower execution, not better caching.

2. **The meaningful metrics are `total_ms` and `state_read_ms`**, which already incorporate the prefetch benefit. These are wall-clock measurements that reflect real performance regardless of cache internals.

3. **Multi-tx block bundling inflates bintrie's cache rates further.** When filtering to single-transaction blocks only, the gap narrows but persists (35% vs 15%) due to Factor 1.

4. **To equalize cache behavior**, one could re-run with `--cache.noprefetch`, which disables the shared cache entirely. This would give a "pure" trie performance comparison but removes a real production optimization.

## Code references (go-ethereum commit 991300c4 / 5d0e18f7)

| File | Lines | What |
|------|-------|------|
| `core/state/reader.go` | 354-460 | `stateReaderWithCache` — the shared slot cache |
| `core/state/reader.go` | 464-530 | `stateReaderWithStats` — hit/miss counter wrapper |
| `core/state/database.go` | 226-234 | `ReadersWithCacheStats()` — creates shared cache + two readers |
| `core/blockchain.go` | 2134-2167 | Prefetcher/processor setup and "Slow block" logging |
| `core/state_prefetcher.go` | 52-122 | Prefetcher goroutine (re-executes txs concurrently) |
| `core/state/reader.go` | 262-284 | Bintrie unified trie vs MPT per-account storage tries |
| `cmd/utils/flags.go` | 1784-1860 | `--cache` flag → cache size allocation |
