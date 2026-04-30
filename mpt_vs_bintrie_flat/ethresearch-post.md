# The Path Towards Binary Tries 3: Flat State Closes the Read Gap

**There's a much better way to visualize this article (with dynamic figures and interactive widgets). If you prefer it, check it at: https://cperezz.github.io/bintrie-benchmarks/mpt_vs_bintrie_flat/index.html**

> **Flat state flips the verdict. Bintrie with flat state is 2.0–2.3× faster than MPT on read-heavy workloads (3.0–3.7× per slot, on read latency) and ~25% slower on `erc20_approve`. The remaining gap is now concentrated in `trie_updates` (root recomputation), not slot resolution.**

This is a follow-up to [Part 2](https://ethresear.ch/t/...) (MPT vs BT-GD5). Same hardware, same workloads, same cold-cache protocol. The new variable: `bt-gd5-flat` — bintrie group-depth 5 with flat-state stem blobs enabled.

---

## S1 — Headline

In Part 2, BT-GD5 was ~1.7× slower than MPT on reads, ~2.5× on writes per storage slot. The dominant cost was `state_read_ms` — every storage slot required walking ~50 binary trie nodes from the disk-resident pathdb.

Flat state changes this. Each SLOAD becomes a single Pebble read of a packed stem blob keyed by `"vX" + stem(31 bytes)`, followed by an in-memory bitmap+offset extraction. Trie traversal is bypassed for reads.

The result, in three numbers — **read latency** (`state_read_ms / slots`, lower is better):

| Benchmark | MPT | BT-GD5 | **BT-GD5-flat** | flat vs MPT |
|:----------|:----|:-------|:----------------|:------------|
| balanceof | 135 µs/slot | 255 µs/slot | **45 µs/slot** | **3.0× faster** |
| mixed | 134 µs/slot | 287 µs/slot | **36 µs/slot** | **3.7× faster** |
| approve | 69 µs/slot | 334 µs/slot | **23 µs/slot** | **3.0× faster** |

Throughput — **all phases combined**, slots resolved per second of wall-clock time:

| Benchmark | MPT slots/s | BT-GD5 slots/s | **BT-GD5-flat slots/s** | flat vs MPT |
|:----------|:------------|:---------------|:------------------------|:------------|
| balanceof | 6,958 | 3,460 | **13,873** | **2.0× faster** |
| mixed | 6,993 | 2,762 | **16,040** | **2.3× faster** |
| approve | 8,741 | 1,790 | **3,494** | **0.4× (slower)** |

> The two tables measure different things and diverge for `approve` on purpose. Read latency is the cost of resolving a single slot from disk; throughput is the rate at which whole blocks finish, including `trie_updates` and commit. For read-heavy workloads they point the same way (read latency dominates total time, so faster reads → higher throughput). For `approve`, BT-GD5-flat reads each slot 3× faster than MPT but spends 85% of its block time in `trie_updates` (vs 31% for MPT) — that phase shift is exactly what §S4 unpacks.

The position: flat state is the single biggest improvement to bintrie performance demonstrated to date. The remaining gap is concentrated in one phase (`trie_updates`) rather than distributed across the read path.

---

## S2 — Methodology delta

Refer to Part 2 for the full setup. Only what changed in Part 3:

- New config `bt-gd5-flat` added (binary + DB + state-actor flat-state metadata).
- 10 cold-cache runs per benchmark for the new config (matching Part 2's BT-GD5 run count).
- All other parameters identical: `--cache 0`, OS page cache dropped between every run, `--debug.logslowblock=0` to capture per-block timing JSON, ~100M gas target per block.

---

## S3 — Reads collapse

The most striking result is the median `state_read_ms` per block:

![Read collapse](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g09_read_collapse.png)

For `erc20_balanceof`, BT-GD5 spends 9,384 ms reading state per block; BT-GD5-flat spends 530 ms. **A 17.7× reduction.** MPT spends 4,971 ms — bintrie-flat resolves storage faster than MPT despite walking a deeper logical trie *because* it doesn't walk the trie at all.

Per-slot total time (`total_ms / slots`) makes this concrete:

![Per-slot total time](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g07_per_slot_total_time.png)

balanceof: 135 / 255 / **45** µs/slot read latency (MPT / BT-GD5 / BT-GD5-flat)
mixed: 134 / 287 / **36** µs/slot read latency
approve: 69 / 334 / **23** µs/slot read latency

**Mechanism.** Without flat state, each SLOAD on a binary trie at groupDepth=5 traverses ~50 group nodes — paths are 31 bytes × 8 bits = 248 bits, grouped into 5-bit chunks, so 248 / 5 ≈ 50 group nodes per stem. With `--cache 0` and a cold OS page cache, every group node access is a Pebble disk lookup. With flat state, the entire path collapses to a single Pebble read at `"vX" + stem(31 bytes)`, returning a packed `(bitmap, values)` blob from which the offset of the requested slot is extracted in memory.

For reads, this is a phase change: from O(depth) trie traversals to O(1) flat-state lookups. The 5.7× speedup over BT-GD5 and the 3.0× speedup over MPT are the direct consequence.

---

## S4 — Writes: the bottleneck shift

For `erc20_approve`, the read-cost saving is real (14× faster `state_read`: 1,341 → 93 ms) but the bottleneck shifts:

![Phase mix shift](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g10_phase_mix_shift.png)

| Phase | BT-GD5 | BT-GD5-flat | Change |
|:------|:-------|:------------|:-------|
| state_read | 1,341 ms (60%) | 93 ms (8%) | **14.4× faster** |
| trie_updates | 745 ms (33%) | 988 ms (85%) | 1.3× slower |
| total | 2,242 ms | 1,169 ms | **1.9× faster** |

Total time still nearly halves vs BT-GD5, but `trie_updates` now dominate. Compared to MPT (`trie_updates = 289 ms`, 31% of approve), bintrie-flat's 988 ms is 3.4× higher — that's the residual gap.

**Why trie updates don't shrink with flat state.** Root recomputation walks every modified trie node from leaf to root. The binary trie is structurally deeper than MPT's hex trie (~50 levels at 1-bit-per-level vs ~5 levels at 4-bits-per-level), so roughly 10× more node hashes per modified slot. Flat state changes how reads resolve, not how writes commit.

This is the new structural ceiling on write performance for binary tries. Closing it requires something different from flat state: parallel hashing across more depth levels (#34032 helped at shallow levels), incremental hashing with cached subtree roots, or moving hash work off the critical path entirely.

---

## S5 — 3-way throughput

![Throughput slots/sec](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g11_slots_per_sec_3way.png)

For read-heavy workloads, bintrie-flat is the clear winner:
- **balanceof**: 13,873 slots/s — 2.0× faster than MPT
- **mixed**: 16,040 slots/s — 2.3× faster than MPT
- **approve**: 3,494 slots/s — 0.4× MPT (still 2.0× faster than non-flat BT-GD5, but losing to MPT)

The block-time distribution is also tighter under flat state — the throughput boxplots show much smaller variance for the bt-gd5-flat config:

![Throughput boxplots](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g02_throughput_boxplots.png)

---

## S6 — Caveats

**Database size asymmetry**. BT-GD5-flat is 507 GB; MPT 1.6 TB; BT-GD5 1.4 TB. Smaller LSM trees have shallower Pebble lookups, so absolute `µs/slot` for bt-gd5-flat may be modestly optimistic. The flat-state advantage is structural (O(1) vs O(depth) lookups) and would hold at any size, but a re-run with an equally-sized DB would tighten the comparison.

**EIP-7825 block fragmentation**. BT-GD5-flat splits the 100M-gas benchmark into ~6 transactions across 2-3 blocks. Per-slot metrics normalize this; per-block totals are not directly comparable.

**Run-count asymmetry**. MPT has 100 cold-cache runs per benchmark; BT-GD5 and BT-GD5-flat have 10 each. This matches Part 2's protocol — variance for the bintrie configs is higher (CV% ~15-20%) but all reported differences are statistically significant.

**Cache hit rate inflation**. BT-GD5-flat shows storage cache hit rates of 68-84%, compared to 38-64% for BT-GD5 and 7-15% for MPT. This is the same `stateReaderWithCache` prefetcher race documented in [Part 2's CACHE_ANALYSIS](https://github.com/CPerezz/bintrie-benchmarks/blob/main/mpt-vs-bintrie/CACHE_ANALYSIS.md) — when reads are faster, the prefetcher wins more races. The wall-clock `total_ms` and `state_read_ms` already incorporate the prefetch benefit and are the authoritative metrics.

![Cache hit panels](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g04_cache_hit_panels.png)

---

## S7 — What's next

`trie_updates` is the remaining bottleneck for write-heavy workloads. Three viable optimization paths:

1. **Parallel hashing across more depth levels.** PR #34032 already parallelizes shallow `InternalNode.Hash` calls. Extending this deeper trades CPU cores for hash latency.
2. **Incremental hashing with cached subtree roots.** Track which subtrees changed in a block and rehash only those, caching subtree roots in memory between blocks.
3. **GC-free arena (PR #34055, still open).** Reduces GC pressure during commit, helps tail latency.

The read story is essentially solved. With bintrie's read-path performance now ahead of MPT, the structural roadmap question shifts from "can binary tries match MPT?" to "can `trie_updates` overhead be amortized down to the MPT range?" Part 4 will probably look at exactly that.

---

## Appendix A — Full timing breakdown

![Hero time breakdown](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g01_hero_time_breakdown.png)

| Benchmark | Config | total_ms | state_read | trie_updates | execution | commit | slots/block |
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

Tables show **means per block**. The companion [analysis_results.json](https://github.com/CPerezz/bintrie-benchmarks/blob/main/mpt_vs_bintrie_flat/analysis_results.json) carries **medians** used for the Mann-Whitney U / bootstrap-CI hypothesis tests (robust to the long tails created by EIP-7825 multi-block fragmentation). Both views are valid; they serve different purposes. Raw per-block CSVs: [data/](https://github.com/CPerezz/bintrie-benchmarks/tree/main/mpt_vs_bintrie_flat/data).
