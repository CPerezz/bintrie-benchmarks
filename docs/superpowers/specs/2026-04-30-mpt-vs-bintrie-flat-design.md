# Design Spec: MPT vs Binary Trie Part 3 — Flat State

**Title:** "The Path Towards Binary Tries 3: Flat State Closes the Read Gap"
**Deliverables:** ethresear.ch markdown post + self-contained HTML report + new benchmark folder with raw artifacts
**Date:** 2026-04-30

---

## Context

[Part 1](https://ethresear.ch/t/narrower-than-expected-optimal-group-depth-for-ethereums-binary-trie/22029) established GD-5 and GD-6 as the optimal group-depth settings for the binary trie. Part 2 (the existing `mpt-vs-bintrie/` report) showed that an optimized BT-GD5 is **~2× slower than MPT on reads and ~3× on writes** when storage state is resolved through trie traversal.

Part 3 addresses the natural follow-up: **what happens when the binary trie reads from a flat-state index instead of walking the trie?** The flat-state design — packed `(bitmap, values)` blobs keyed by 31-byte stem — is part of the EIP-7864 / verkle-direction work. A new geth branch (`bintrie-flat-state`, commit `7d2e7cbe`) and updated state-actor (PR#19 + local fixes) make end-to-end flat-state benchmarking possible for the first time.

Sources for this report (from the remote `stateless-bloatnet-benchmarks` machine, `/home/CPerezz/bintrie-benchmarks/mpt-vs-bintrie/`):
- `FLAT_STATE_ANALYSIS.md` — the engineering team's working analysis of the 3-way comparison
- `BENCHMARK_PROCEDURE.md` — end-to-end procedure for the flat-state campaign (DB gen, deployment, runs, extraction)

The headline finding the report must communicate: **flat state flips the verdict**. Bintrie-flat is **2.0–2.3× faster than MPT for reads** (and 3.0–3.7× faster than MPT *per slot*). For writes, flat state cuts state_read by 14× but the bottleneck shifts to `state_hash` (root recomputation), so bintrie-flat is still ~25% slower than MPT on approve. This is a phase change, not a uniform speedup, and the report must present the asymmetry honestly.

---

## Deliverables

### 1. New folder `mpt_vs_bintrie_flat/` (underscores per user preference)

Layout:

```
mpt_vs_bintrie_flat/
├── README.md                  # Campaign summary, ~7-8KB, modeled on mpt-vs-bintrie/README.md
├── ethresearch-post.md        # Concise Part 3 narrative, 10-15KB
├── index.html                 # Self-contained dark-themed report (Part 2 style verbatim)
├── FLAT_STATE_ANALYSIS.md     # Source doc, verbatim from remote
├── BENCHMARK_PROCEDURE.md     # Source doc, verbatim from remote
├── analysis_results.json      # Aggregated metrics produced by analyze_data.py
├── data/                      # All CSVs for mpt, bt-gd5, bt-gd5-flat (~530KB)
│   ├── mpt_vs_bintrie_consolidated.csv
│   ├── bt-gd5-flat_*.csv      # New flat-config CSVs
│   └── (existing mpt and bt-gd5 CSVs)
├── logs/                      # Geth + test logs (~6MB, group-depth pattern)
│   ├── mpt/                   #   ~300 files (100 runs × 3 benchmarks, both geth + test logs)
│   ├── bt-gd5/                #   ~30 files
│   └── bt-gd5-flat/           #   ~30 files
├── graphs/                    # Dark PNGs for HTML (matplotlib dark theme)
├── graphs-light/              # Light PNGs for ethresearch markdown rendering
└── scripts/
    ├── extract_csv.py         # From remote (pre-updated for flat config)
    ├── analyze_data.py        # Ported from Part 2, extended for 3-way
    ├── generate_graphs.py     # Ported from Part 2, extended for 3-way
    ├── run_benchmarks.sh      # From remote (handles flat-state run flow)
    ├── generate_db.sh         # From remote
    ├── post_gen_bloat.sh      # From remote
    └── spamoor_ramp_v2.sh     # From remote
```

**Excluded from the folder:**
- `bin/` — binaries are too large (~70MB+ each), follow Part 2 git pattern; README references commit SHAs and build dates instead
- `dbs/` — multi-TB Pebble DBs, not transferable
- `results/` — raw execution-specs JSON output (~670MB), too large; CSVs in `data/` are the distilled form
- `tools/fix_snap/` — internal benchmarking workaround, intentionally not surfaced (per user direction)

### 2. Landing page card

Append a Part 3 card to repo root `index.html`, matching the existing Part 2 card pattern. Title: "MPT vs Binary Trie Part 3 — Flat State"; one-line subtitle: "Flat state makes bintrie 2× faster than MPT for reads"; link to `mpt_vs_bintrie_flat/index.html`.

### 3. Cleanup

Delete the existing empty `mpt-vs-bintrie-flat/` (hyphenated) folder.

---

## Methodology summary (for the report)

| Parameter | Value |
|:----------|:------|
| Machine | Bare metal — AMD EPYC 9454P 48-Core (96 threads), 126 GB RAM, 3.5 TB SSD (md RAID), Ubuntu 24.04 LTS (same as Part 2) |
| Configurations | `mpt` (upstream `5d0e18f7`) vs `bt-gd5` (bintrie fork `991300c4`) vs `bt-gd5-flat` (bintrie-flat-state `7d2e7cbe`) |
| Databases | MPT 1.6 TB, BT-GD5 1.4 TB, BT-GD5-flat 507 GB |
| Protocol | Cold cache (OS page cache dropped + `--cache 0` between runs) |
| Gas target | 100M per block |
| Runs | MPT: 100 per benchmark, BT-GD5: 10 per benchmark, BT-GD5-flat: 10 per benchmark |
| Benchmarks | `erc20_balanceof` (reads), `erc20_approve` (writes), `mixed_sload_sstore` (50/50) |

Same hardware as Part 2 → **absolute numbers are directly comparable** between Part 2 and Part 3 (note this explicitly in the post).

### Block-shape asymmetry to address

BT-GD5-flat's bintrie genesis activates Osaka, which means EIP-7825's 16M per-tx gas cap is in effect. The 100M-gas benchmark splits into ~6 transactions, landing across 2-3 blocks. Per-block totals are smaller; per-slot metrics (`µs/slot`, `slots/s`) normalize this and are the authoritative comparison.

MPT and BT-GD5 (older binaries, pre-Osaka semantics on those genesis blocks) send single 100M-gas txs. The report calls this out in the methodology section and uses per-slot metrics in the headline charts.

### Cache hit rate caveat (carry-over from Part 2)

BT-GD5-flat shows even higher storage cache rates (68–84%) than BT-GD5 (38–64%) and MPT (7–15%). This is explained by the same `stateReaderWithCache` prefetcher race documented in Part 2's `CACHE_ANALYSIS.md` — when reads are faster, the prefetcher wins more races. The report will reference Part 2's analysis rather than re-stating it. `total_ms` and `state_read_ms` remain the authoritative wall-clock metrics.

---

## Visualization plan

Regenerate 4 essentials from Part 2 as 3-way charts; add 3 new flat-specific charts. Both dark (`graphs/`) and light (`graphs-light/`) variants for each.

| ID | Name | 3-way? | Purpose |
|:---|:-----|:-------|:--------|
| g01 | hero_time_breakdown | regen | Stacked phase bars (state_read / state_hash / execution / commit) per benchmark per config — *the* hero chart |
| g02 | throughput_boxplots | regen | Mgas/s and slots/s distributions (boxplot per config per benchmark) |
| g04 | cache_hit_panels | regen | Storage cache hit rate per config; 3 panels (one per benchmark), reference Part 2 caveat |
| g07 | per_slot_total_time | regen | µs/slot bars: shows BT-GD5 → BT-GD5-flat → MPT ranking inversion (the headline) |
| g09 | read_collapse | NEW | state_read_ms per config × benchmark — visualizes the 14× collapse |
| g10 | phase_mix_shift | NEW | Stacked-100% bars for `erc20_approve`, showing how flat shifts the bottleneck from state_read to state_hash |
| g11 | slots_per_sec_3way | NEW | Single-panel 3-way bars of slots/sec with annotated multipliers (2.0× / 4.0× etc.) |

Graphs g03/g05/g06/g08 from Part 2 are *gradient* charts inside the read-bound regime (cold-tail effect, per-miss read cost, evm-tax scatter, per-slot write cost). With flat state collapsing the read-bound regime to ~constant time, those charts visually compress to non-stories — they're kept available in `generate_graphs.py` but not embedded in the Part 3 report.

---

## ethresearch-post.md structure (concise, 10-15KB)

The post is positioned as an update to Part 2, not a standalone re-presentation. It explicitly references Part 2 for shared methodology and assumes the reader has either read Part 2 or will do so for full context.

### S1 — Executive summary

Headline: **Flat state flips the verdict**. Bintrie-flat is 2.0–2.3× faster than MPT for reads (per gas) and 3.0–3.7× faster per slot. For writes (`approve`), the read-cost saving is real (14× faster state_read) but `state_hash` becomes the dominant cost, leaving bintrie-flat ~25% slower than MPT on approve. The remaining gap is now in trie root recomputation, not slot resolution.

Position statement: "Flat state is the single biggest improvement to bintrie performance demonstrated to date. The remaining gap is concentrated in one phase (`state_hash`) rather than distributed across the read path."

### S2 — What's new since Part 2

- New geth binary: `bintrie-flat-state` branch, commit `7d2e7cbe` (built 2026-04-27)
- New state-actor with three flat-state metadata fixes (architecture-level, not workarounds): `WriteDatabaseVersion(9)`, `"v"` prefix on PathDB metadata writes, `IsBintrie:true` in `SnapshotGenerator`. Without these, geth ignores the stem-blob layer entirely
- New 507 GB BT-GD5-flat DB (smaller than the 1.4 TB BT-GD5 / 1.6 TB MPT — caveat noted)
- Same hardware as Part 2, so absolute numbers are comparable
- Block-shape note: BT-GD5-flat activates Osaka at genesis → EIP-7825 splits 100M-gas benchmarks into ~6 txs / 2-3 blocks. Per-slot metrics are authoritative

### S3 — Methodology delta (brief)

Refer to Part 2 for the full setup; this section only states what changed:
- New config `bt-gd5-flat` added (binary + DB)
- 10 cold-cache runs per benchmark for the new config (matching Part 2's BT-GD5 run count)
- All other parameters identical to Part 2

### S4 — Reads collapse (the headline finding)

Embed: g09 (read_collapse), g07 (per_slot_total_time)

Numbers:
- balanceof: 135 / 255 / **45** µs/slot (MPT / BT-GD5 / BT-GD5-flat)
- mixed: 134 / 287 / **36** µs/slot
- approve: 69 / 334 / **23** µs/slot

Mechanistic explanation: each SLOAD becomes a single Pebble read of the stem blob at `"vX" + stem(31 bytes)`, followed by a bitmap+offset extraction in memory. This replaces ~50 trie node reads — binary trie paths are 31 bytes × 8 bits = 248 bits, grouped into 5-bit chunks at groupDepth=5, so 248/5 ≈ 50 group nodes per traversal. With `--cache 0` and cold OS cache, every avoided node read is a saved Pebble lookup.

### S5 — Writes: the bottleneck shift

Embed: g10 (phase_mix_shift), g01 (hero_time_breakdown)

For `erc20_approve`:
- BT-GD5: state_read 60% / state_hash 33% — read-bound
- BT-GD5-flat: state_read 8% / state_hash 85% — hash-bound
- MPT: state_read 61% / state_hash 31% — read-bound (with shallower hex trie, less hash work)

The state_hash time itself doesn't decrease for bintrie-flat — root recomputation still walks the modified trie nodes from leaves to root. With binary trie depth ~50 vs MPT hex trie depth ~5, bintrie-flat has 10× more hash work per modified slot.

This is the structural ceiling for flat state on writes. Closing it requires either: parallel hashing across more cores (in progress), a different commit strategy, or moving more of the trie work off the critical path.

### S6 — 3-way throughput

Embed: g02 (throughput_boxplots), g11 (slots_per_sec_3way)

Headline numbers (slots/sec):
- balanceof: MPT 6,958 / BT-GD5 3,460 / **BT-GD5-flat 13,873** (2.0× faster than MPT)
- mixed: MPT 6,993 / BT-GD5 2,762 / **BT-GD5-flat 16,040** (2.3× faster)
- approve: MPT 8,741 / BT-GD5 1,790 / **BT-GD5-flat 3,494** (0.4× — slower)

### S7 — Caveats

- **DB size asymmetry**: 507 GB vs 1.4 / 1.6 TB. Smaller LSM tree → shallower Pebble lookups. The flat-state advantage is structural (O(1) vs O(depth)) but absolute µs/slot for bt-gd5-flat may be modestly optimistic
- **EIP-7825 block fragmentation**: addressed via per-slot metrics
- **Run count asymmetry**: MPT 100 runs, bintrie configs 10 runs (this matches Part 2)
- **Cache hit rate**: still inflated by prefetcher race; reference Part 2's `CACHE_ANALYSIS.md`

Embed: g04 (cache_hit_panels) here

### S8 — What's next

State_hash is the remaining bottleneck for write workloads. Optimization paths: (a) parallel hashing for more depth levels (#34032 already covers shallow), (b) incremental hashing with cached subtree roots, (c) GC-free arena (#34055, still open). The read story is essentially solved.

---

## index.html structure

Mirrors the ethresearch-post structure 1:1. Reuses Part 2's `mpt-vs-bintrie/index.html` design system **verbatim**:
- IBM Plex Mono / IBM Plex Sans
- Background `#0A0E17`, card surface `#0F172A`, border `#1E293B`
- Amber accent `#F59E0B`, slate body text `#E2E8F0`
- Same hero-title gradient, same meta-grid, same nav-pill, same section transitions

Sections: hero with meta-grid (machine/configs/runs/date), sticky section nav (S1–S8 + caveats), then content matching the MD post. Tables and graphs embedded inline.

**Widgets**: only included if a *clearly useful* one emerges during implementation (e.g., a benchmark-toggle for the phase-mix chart). Default is no widgets — Part 2's two widgets were specific to that report's content and don't have obvious analogs here. Decided at implementation time, not committed up-front.

---

## README.md structure

Modeled directly on `mpt-vs-bintrie/README.md`. Sections:

1. **Title + 1-line headline** with link to ethresearch-post and HTML
2. **Campaign table** (machine, configs, DB sizes, contract, seed account)
3. **Geth binaries** table (geth-mpt commit, geth-bintrie commit for both BT-GD5 and BT-GD5-flat)
4. **State-actor** table (commit + flat-state fixes)
5. **Benchmarks** table (one row per benchmark)
6. **Data completeness** (3-config matrix)
7. **Raw results** table (averages per config × benchmark)
8. **Cache rate note** (one paragraph, link to Part 2 CACHE_ANALYSIS)
9. **Contents** (folder pointers)
10. **Procedure** (brief — refer to BENCHMARK_PROCEDURE.md for details)
11. **Reproducing** with the three callouts (state-actor metadata, EIP-7825, group-depth-must-match)

Length target: ~7-8 KB.

---

## Data flow

```
Remote (stateless-bloatnet-benchmarks via tsh)
   │
   │  tsh scp -r (data/, scripts/, logs/, source MDs)
   ▼
local mpt_vs_bintrie_flat/{data,logs,scripts,FLAT_STATE_ANALYSIS.md,BENCHMARK_PROCEDURE.md}
   │
   │  python3 scripts/analyze_data.py
   ▼
analysis_results.json (3-config aggregates)
   │
   │  python3 scripts/generate_graphs.py (regen + new)
   ▼
graphs/*.png + graphs-light/*.png
   │
   │  hand-author from FLAT_STATE_ANALYSIS.md + analysis_results.json + graphs
   ▼
README.md + ethresearch-post.md + index.html
```

---

## Commit strategy (one per logical chunk)

1. **`Fetch flat-state benchmark artifacts from remote`**
   - Adds `mpt_vs_bintrie_flat/{FLAT_STATE_ANALYSIS.md, BENCHMARK_PROCEDURE.md, data/, logs/, scripts/}`
   - Removes empty `mpt-vs-bintrie-flat/`

2. **`Generate 3-way graphs and analysis_results.json for Part 3`**
   - Adds `graphs/*.png`, `graphs-light/*.png`, `analysis_results.json`
   - Updates `scripts/analyze_data.py` and `scripts/generate_graphs.py` for 3-way support

3. **`Add MPT vs Binary Trie Part 3 README, ethresearch post, and HTML report`**
   - Adds `README.md`, `ethresearch-post.md`, `index.html`

4. **`Add Part 3 card to landing page`**
   - Updates root `index.html` with the Part 3 card

---

## Open questions / non-decisions

The following are deliberately deferred to implementation:
- Exact widget design (decided at implementation time, default: no widgets)
- Whether `analyze_data.py` needs structural changes for the EIP-7825 block fragmentation (validated by re-running with current data; if the existing `gas > 500K` filter drops legitimate flat-config benchmark blocks, lower the threshold to 100K and document)

---

## Out of scope

- Re-running the benchmark campaign (data is fixed; report only)
- Surfacing the `fix_snap` tool or its workflow (internal plumbing per user direction)
- Updating Part 1 or Part 2 reports
- Authoring a new ethresearch post for the landing page (the existing landing page only needs a card)
