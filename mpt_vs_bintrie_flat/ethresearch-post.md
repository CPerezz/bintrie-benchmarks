# The Path Towards Binary Tries 3: Flat State Closes the Read Gap

**There's a much better way to visualize this article (with dynamic figures and interactive widgets). If you prefer it, check it at: https://cperezz.github.io/bintrie-benchmarks/mpt_vs_bintrie_flat/index.html**

> **Flat state flips the verdict. Bintrie with flat state is 1.8–2.4× faster than MPT on read-heavy workloads (2.5–3.8× per slot on read latency) and statistically on par with MPT on `erc20_approve` end-to-end (median +10%, not significant) while resolving ~2.4× fewer slots/sec there. The remaining gap is now concentrated in `trie_updates` (root recomputation), not slot resolution.**

This is a follow-up to [Part 2](https://ethresear.ch/t/the-path-towards-binary-tries-2-mpt-vs-bt-gd5/22253) (MPT vs BT-GD5). Same hardware, same workloads, same cold-cache protocol. The new variable: `bt-gd5-flat` — bintrie group-depth 5 with flat-state stem blobs enabled.

> All headline figures are **medians per block**, matching the companion [analysis_results.json](https://github.com/CPerezz/bintrie-benchmarks/blob/main/mpt_vs_bintrie_flat/analysis_results.json) and the embedded graphs. Means per block (Appendix A) run 10–35% higher than medians for the bintrie configs because of the long tail introduced by EIP-7825 block fragmentation (§S6).

---

## S1 — Headline

In Part 2, BT-GD5 was ~1.7× slower than MPT on reads per storage slot. The dominant cost was `state_read_ms` — without a flat layer, every storage slot was resolved by walking the binary trie.

Flat state changes this. Each SLOAD becomes a single Pebble read of a packed stem blob keyed by `"vX" + stem(31 bytes)`, followed by an in-memory bitmap+offset extraction. This puts bintrie's storage reads on the same footing as MPT, whose SLOADs are already served by its flat **snapshot** in ~1 read (the trie is not walked for reads — see the mechanism in §S3).

The result, in three numbers — **read latency** (median `state_read_ms / storage_slots_read`, lower is better):

| Benchmark | MPT | BT-GD5 | **BT-GD5-flat** | flat vs MPT |
|:----------|:----|:-------|:----------------|:------------|
| balanceof | 135 µs/slot | 216 µs/slot | **55 µs/slot** | **2.5× faster** |
| mixed | 135 µs/slot | 334 µs/slot | **35 µs/slot** | **3.8× faster** |
| approve | 139 µs/slot | 364 µs/slot | **46 µs/slot** | **3.0× faster** |

Throughput — **all phases combined**, slots resolved per second of wall-clock time (median per block):

| Benchmark | MPT slots/s | BT-GD5 slots/s | **BT-GD5-flat slots/s** | flat vs MPT |
|:----------|:------------|:---------------|:------------------------|:------------|
| balanceof | 6,980 | 4,128 | **12,486** | **1.8× faster** |
| mixed | 6,987 | 1,991 | **16,520** | **2.4× faster** |
| approve | 8,715 | 1,757 | **3,555** | **0.4× (slower)** |

> The two tables measure different things and diverge for `approve` on purpose. Read latency is the cost of resolving a single slot; throughput is the rate at which whole blocks finish, including `trie_updates` and commit. For read-heavy workloads they point the same way. For `approve`, BT-GD5-flat reads each slot ~3× faster than MPT but spends ~80% of its block time in `trie_updates` (vs 31% for MPT) — so it resolves ~2.4× fewer slots/sec despite faster reads. End-to-end, approve's per-block wall-clock is only ~10% above MPT and **not statistically significant** (§S6) because EIP-7825 makes flat's blocks smaller; the honest write comparison is the per-slot/throughput one. §S4 unpacks the phase shift.

The position: flat state is the single biggest improvement to bintrie read performance demonstrated to date — it removes bintrie's structural read penalty and brings it to parity with (and, at this database size, ahead of) MPT. The remaining gap is concentrated in one phase (`trie_updates`) rather than distributed across the read path.

---

## S2 — Methodology delta

Refer to Part 2 for the full setup. Only what changed in Part 3:

- New config `bt-gd5-flat` added (binary + DB + state-actor flat-state metadata).
- 10 cold-cache runs per benchmark for the new config (matching Part 2's BT-GD5 run count); MPT has 100.
- All other parameters identical: `--cache 0`, OS page cache dropped between every run, `--debug.logslowblock=0` to capture per-block timing JSON, ~100M gas target per block.

One asymmetry to keep in mind throughout (expanded in §S6): only the bintrie-flat branch activates Osaka (EIP-7825), so its 100M-gas benchmark fragments into ~6 transactions across 2–3 smaller blocks, while MPT and BT-GD5 run a single 100M-gas block. Per-slot metrics normalize the slot count, but not the block shape.

---

## S3 — Reads collapse

The median `state_read_ms` per block:

![Read collapse](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g09_read_collapse.png)

For `erc20_balanceof`, BT-GD5 spends 7,935 ms reading state per block; BT-GD5-flat spends 469 ms. **Per slot, that is a 3.9× read-latency reduction** (216 → 55 µs/slot). The per-block ratio looks larger (16.9×), but roughly 3× of that is just flat's smaller EIP-7825 blocks — per-block totals are not comparable across configs (§S6), so the per-slot number is the honest one. MPT spends 4,956 ms (135 µs/slot).

Per-slot **total** time (`total_ms / storage_slots_read`, median) tells the same story for read-heavy work — and shows the write penalty for `approve`:

![Per-slot total time](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g07_per_slot_total_time.png)

| Benchmark | MPT | BT-GD5 | **BT-GD5-flat** |
|:----------|:----|:-------|:----------------|
| balanceof | 143 µs/slot | 242 µs/slot | **83 µs/slot** |
| mixed | 143 µs/slot | 502 µs/slot | **61 µs/slot** |
| approve | 230 µs/slot | 569 µs/slot | **563 µs/slot** |

For `approve`, BT-GD5-flat's per-slot *total* time (563 µs) is essentially tied with non-flat BT-GD5 (569 µs) even though its reads are 3× faster — the cost has moved entirely into `trie_updates` (§S4).

**Mechanism.** The three configs resolve a cold SLOAD differently:

| Config | Per-SLOAD read path (cold cache) | Disk reads per slot |
|:-------|:----------------------------------|:--------------------|
| **MPT** | Leaf served from the flat **snapshot** (`snapStorage`); the trie is *not* walked for reads | ~1 |
| **BT-GD5** (no flat) | No flat layer → binary-trie traversal; upper group nodes amortize in-memory within a block, so the marginal cost is a few node reads, not the full ~50-node logical path to the stem | a few |
| **BT-GD5-flat** | Single Pebble lookup at `"vX" + stem(31 bytes)` → packed `(bitmap, values)` blob → in-memory offset extraction | ~1 |

So MPT and BT-GD5-flat both resolve a storage leaf in ~1 flat read; **the flat-state win over MPT is not a "fewer reads" effect.** In fact, per cold disk read the two are statistically indistinguishable (median `ms_per_cache_miss` on balanceof: MPT 146 µs vs flat 135 µs, *p* = 1.0). Flat-state's lower `state_read_ms`/slot comes from two things, both of which §S6 flags as partial confounders:

- **Fewer disk trips per slot.** A stem blob packs many slots, and the `stateReaderWithCache` prefetcher wins more races when reads are fast, so flat does ~0.4 disk reads/slot vs MPT's ~0.9 on balanceof.
- **A 3× smaller LSM.** BT-GD5-flat's database is 507 GB vs MPT's 1.6 TB. (Note this does *not* obviously make individual reads cheaper here — per-miss latency is equal-or-higher for flat — but it interacts with the cache/prefetch behavior; a same-size re-run is needed to isolate it.)

The structural takeaway is the robust one: **without flat state bintrie is ~1.6× slower than MPT on reads; with it, bintrie reaches MPT-snapshot parity and, at this DB size and prefetch regime, pulls ahead by 2.5–3.8×.**

**A note on block shape.** The numbers above are medians across all benchmark blocks. Single-transaction blocks (the cleanest cold comparison) give a tighter ratio — MPT ~135 µs/slot vs flat ~77 µs/slot, ≈**1.8×** — versus the 2.5× balanceof median. The difference is the prefetcher race: multi-tx blocks let the prefetcher goroutine warm the per-block shared cache for later transactions, so the main processor's `time.Since(start)` increasingly measures cache-hit fast paths. The same `stateReaderWithCache` race is documented in [Part 2's CACHE_ANALYSIS.md](https://github.com/CPerezz/bintrie-benchmarks/blob/main/mpt-vs-bintrie/CACHE_ANALYSIS.md).

---

## S4 — Writes: the bottleneck shift

For `erc20_approve`, the read-cost saving is real (12.8× faster `state_read`: 1,064 → 83 ms median) but the bottleneck shifts:

![Phase mix shift](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g10_phase_mix_shift.png)

| Phase | BT-GD5 | BT-GD5-flat | Change |
|:------|:-------|:------------|:-------|
| state_read | 1,064 ms (53%) | 83 ms (8%) | **12.8× faster** |
| trie_updates | 738 ms (37%) | 829 ms (81%) | 1.1× slower |
| total | 2,000 ms | 1,030 ms | **1.9× faster** |

Total time still nearly halves vs BT-GD5, but `trie_updates` now dominates. Compared to MPT (`trie_updates = 288 ms`, 31% of approve), bintrie-flat's 829 ms is 2.9× higher — and per slot written, the gap is **~6.75×** (bootstrap CI 6.3–7.4×). That is the residual gap.

**Why trie updates don't shrink with flat state.** Flat state flattens *leaf* reads, but root recomputation needs the **intermediate** nodes along every modified path — and those are not in the flat layer, so they are read (cold) from the trie and rehashed. The binary trie is far deeper than MPT's hex trie (~248 bit-levels, ≈50 group nodes per stem at groupDepth=5, versus ~5–7 hex levels), so each modified slot pulls roughly an order of magnitude more intermediate nodes through the read-and-hash path. The measured ~6.75×/slot hashing cost is the consequence. Flat state changes how leaves resolve, not how roots recompute.

This is the new structural ceiling on write performance for binary tries. Closing it requires something different from flat state: parallel hashing across more depth levels (#34032 helped at shallow levels), incremental hashing with cached subtree roots, or moving hash work off the critical path entirely.

---

## S5 — 3-way throughput

![Throughput slots/sec](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g11_slots_per_sec_3way.png)

For read-heavy workloads, bintrie-flat is the clear winner (median slots/s):
- **balanceof**: 12,486 slots/s — 1.8× faster than MPT
- **mixed**: 16,520 slots/s — 2.4× faster than MPT
- **approve**: 3,555 slots/s — 0.4× MPT (still ~2.0× faster than non-flat BT-GD5, but losing to MPT)

The block-time distribution is also tighter under flat state (CV ≈ 7%, vs ≈ 20% for BT-GD5 on read-heavy benchmarks) — the throughput boxplots show much smaller variance for the bt-gd5-flat config:

![Throughput boxplots](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g02_throughput_boxplots.png)

---

## S6 — Caveats

**Reads hit a flat layer in *both* MPT and bintrie-flat.** MPT's SLOADs are served by its flat snapshot (~1 read) and bintrie-flat's by the stem blob (~1 read); per cold disk read the two are statistically indistinguishable (balanceof `ms_per_cache_miss`: 146 vs 135 µs, *p* = 1.0, and on `approve`/`mixed` flat is actually *higher* per miss). So the read headline is **not** a "1 vs 5 reads" structural win — it is driven by (a) flat taking fewer disk trips per slot (blob packing + prefetcher race) and (b) the database-size asymmetry below. The structural claim that survives is parity-plus: flat removes bintrie's traversal penalty.

**Database size asymmetry.** BT-GD5-flat is 507 GB; MPT 1.6 TB; BT-GD5 1.4 TB. This ~3× gap is **mostly a generation-target choice** (the flat DB was built to a 500 GB target vs ~1.2 TB for the others), not an intrinsic flat-state property — though flat blobs are genuinely more compact than per-slot snapshot entries. A same-size re-run is the single most important follow-up; until then, treat the 2.5–3.8× read multiple as an upper bound and the ~1.8× single-tx number as the size-and-shape-controlled estimate.

**Gas-schedule difference, and why it doesn't distort the comparison.** MPT runs EIP-2929 (Prague) gas; the bintrie configs run EIP-4762 (Osaka). Despite that, the measured `gas_per_slot` is within **0.2%** across MPT and BT-GD5-flat for every benchmark (≈2,722 gas/read-slot on balanceof, ≈22.9k gas/written-slot on approve), so "100M gas" buys the same slot count and the per-slot comparison is not distorted by the schedule.

**EIP-7825 block fragmentation.** Only the bintrie-flat branch activates Osaka, so its 100M-gas benchmark splits into ~6 transactions across 2–3 smaller blocks while MPT and BT-GD5 run a single block. Per-slot metrics normalize the slot count, but the multi-tx shape also feeds the prefetcher race (above) and is why per-block totals (e.g. the 16.9× read-collapse) are not directly comparable.

**Write counter.** The bintrie binaries' `storage_slots_written` counter is unreliable: BT-GD5 reports 0 written slots on `approve` even though its 738 ms `trie_updates` time proves writes occurred. Read-heavy throughput is unaffected (writes ≈ 0 there for all configs) and the flat-vs-MPT `approve` throughput is valid (both count writes), but BT-GD5's `approve` throughput is read-only, so "flat is ~2× faster than BT-GD5 on approve" is a lower bound.

**Run-count asymmetry and significance.** MPT has 99 analyzed runs per benchmark; BT-GD5 and BT-GD5-flat have 9 each (yielding 18–27 EIP-7825 blocks). Inference therefore rests on ~9 independent runs for the bintrie configs; the per-block Mann-Whitney/bootstrap *n* overstates independence (within-run blocks are correlated), so we also report the per-run Welch test. **All read-path differences are significant across all three tests. The end-to-end `approve` total-time difference (flat vs MPT) is NOT significant** (Mann-Whitney *p* = 1.0, bootstrap ratio CI [0.01, 2.44]) — flat and MPT finish approve blocks in statistically indistinguishable wall-clock time. Variance (CV%): MPT ≈ 2–5%, bt-gd5-flat ≈ 7%, BT-GD5 up to ≈ 21% on read-heavy benchmarks.

**Cache hit rate.** Median per-block storage cache hit rates: MPT 7–15%, BT-GD5 35–73%, BT-GD5-flat 11–42% — note BT-GD5, not flat, shows the highest medians. All bintrie configs run elevated versus MPT because of the same `stateReaderWithCache` prefetcher race ([Part 2's CACHE_ANALYSIS](https://github.com/CPerezz/bintrie-benchmarks/blob/main/mpt-vs-bintrie/CACHE_ANALYSIS.md)). The wall-clock `total_ms` and `state_read_ms` already incorporate the prefetch benefit and are the authoritative metrics.

![Cache hit panels](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g04_cache_hit_panels.png)

---

## S7 — What's next

`trie_updates` is the remaining bottleneck for write-heavy workloads. Three viable optimization paths:

1. **Parallel hashing across more depth levels.** PR #34032 already parallelizes shallow `InternalNode.Hash` calls. Extending this deeper trades CPU cores for hash latency.
2. **Incremental hashing with cached subtree roots.** Track which subtrees changed in a block and rehash only those, caching subtree roots in memory between blocks. (The gain is bounded for keccak-scattered writes, which rarely share dirty subtrees, so it helps most for hot/co-located stems.)
3. **GC-free arena (PR #34055, still open).** Reduces GC pressure during commit, helps tail latency.

The read story is now a parity story: with bintrie's read path level with MPT's flat snapshot, the structural roadmap question shifts from "can binary tries match MPT on reads?" to "can `trie_updates` overhead be amortized down to the MPT range?" Note this is all about *full-node* read latency — flat state does nothing for witness generation, proof sizes, or stateless verification, which still derive from the trie nodes and are the broader motivation for EIP-7864. Part 4 will probably look at the write path.

---

## Appendix A — Full timing breakdown

![Hero time breakdown](https://raw.githubusercontent.com/CPerezz/bintrie-benchmarks/main/mpt_vs_bintrie_flat/graphs-light/g01_hero_time_breakdown.png)

| Benchmark | Config | total_ms | state_read | trie_updates | execution | commit | slots/block |
|:----------|:-------|:---------|:-----------|:-------------|:----------|:-------|:------------|
| erc20_balanceof | MPT | 5,264 | 4,956 (94%) | 0 | 282 | 28 | 36,742 |
| | BT-GD5 | 8,901 | 7,935 (89%) | 0 | 964 | 25 | 36,741 |
| | **BT-GD5-flat** | **658** | **469 (71%)** | 2 | 182 | 9 | 6,114 |
| mixed_sload_sstore | MPT | 3,352 | 3,151 (94%) | 0 | 181 | 18 | 23,418 |
| | BT-GD5 | 3,470 | 2,302 (66%) | 412 | 65 | 56 | 5,556 |
| | **BT-GD5-flat** | **660** | **372 (56%)** | 3 | 265 | 10 | 11,691 |
| erc20_approve | MPT | 939 | 570 (61%) | 288 | 45 | 31 | 8,188 |
| | BT-GD5 | 2,000 | 1,064 (53%) | 738 | 66 | 65 | 4,094 |
| | **BT-GD5-flat** | **1,030** | **83 (8%)** | **829 (81%)** | 68 | 6 | 4,086 |

Tables show **medians per block** (matching the companion [analysis_results.json](https://github.com/CPerezz/bintrie-benchmarks/blob/main/mpt_vs_bintrie_flat/analysis_results.json), which also carries the Mann-Whitney U / bootstrap-CI hypothesis tests — robust to the long tails from EIP-7825 multi-block fragmentation). Means per block run 10–35% higher for the bintrie configs; raw per-block CSVs are in [data/](https://github.com/CPerezz/bintrie-benchmarks/tree/main/mpt_vs_bintrie_flat/data). Throughput (§S1/§S5) is the median of per-block `slots/s`; because block sizes vary under EIP-7825, it is **not** this table's `slots/block ÷ total_ms`.

> **Note on `mixed_sload_sstore`.** This workload is ~90% reads / 10% writes (not an even split). In these runs the write fraction committed almost no storage slots for MPT and BT-GD5-flat (`trie_updates` ≈ 0; `storage_slots_written` ≈ 0), so for those configs it behaves as a second read-heavy workload — which is why flat's throughput on `mixed` is its highest. BT-GD5 is the outlier (`trie_updates` ≈ 412 ms): a plausible explanation is that Osaka system-contract state (touched each block) is resolved through the trie rather than the flat layer for the bintrie configs, but we have not isolated this and treat it as a hypothesis.
