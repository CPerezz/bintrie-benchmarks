# Wider Isn't Better: Optimal Group Depth for Ethereum's Binary Trie

*Full interactive report with SVG diagrams: [GitHub Pages link pending]*

> **GD-4 is optimal.** We benchmarked four binary trie group-depth configurations on 360 GB databases with 400 million state entries. GD-4 delivers statistically identical read performance to GD-8 (p=0.045, borderline) but **45% faster writes** (p < 1e-9). The asymmetry is decisive: 3% read sacrifice buys a 45% write gain.

---

## S1 -- Executive Summary

The binary trie is on the [Ethereum protocol strawman](https://strawmap.org/) as a future state tree replacement. No binary trie implementation has been benchmarked at scale -- not group depth, not anything else. With this transition on the roadmap, assessing performance characteristics is a prerequisite for informed prototyping. The geth implementation ([EIP-7864](https://eips.ethereum.org/EIPS/eip-7864)) exposes a `--bintrie.groupdepth` parameter that controls how binary levels are packed into on-disk nodes; this study benchmarks four configurations to determine the optimal setting.

> **Bottom line:** GD-4 is optimal -- statistically identical read performance to GD-8 (p=0.045), but 45% faster writes (p < 1e-9). A 3% read sacrifice buys a 45% write gain.

### What we tested

Four group-depth configurations (GD-1, GD-2, GD-4, GD-8) on identical 360 GB databases with ~400 million state entries. Five benchmark types -- two synthetic (raw SLOAD/SSTORE) and three ERC20 contract workloads -- each run 9 times under a cold-cache protocol. All results use medians with [Mann-Whitney U](https://en.wikipedia.org/wiki/Mann%E2%80%93Whitney_U_test) significance tests.

### What we found

- **Reads confirm the intuition** (S4): GD-8 reads are 56% faster than GD-1 for ERC20 workloads. But GD-4→GD-8 gains only 3% more -- diminishing returns.
- **Writes reveal the surprise** (S5): GD-8 writes are *nearly 2x slower* than GD-4. Each GD-8 node contains a 255-node internal binary subtree that must be rehashed on every modification -- 17x the work of a GD-4 node (15 internal nodes).
- **The trade-off is decisive** (S6): GD-4 sacrifices 3% on reads but gains 45% on writes. For Ethereum's balanced read/write workload, GD-4 dominates.

### How to read this post

S2 Background covers the binary trie and group depth concept. S3 Methodology details the benchmark setup (collapsible). S4--S6 present the results in a narrative arc: reads, writes, then the trade-off. S7 Patterns examines cross-cutting observations, and S8 Conclusions gives the recommendation and open questions.

---

## S2 -- Background

### What is the Binary Trie?

EIP-7864 proposes replacing Ethereum's Merkle Patricia Trie (MPT) with a binary trie. The binary trie unifies the account trie and all storage tries into a single tree, uses SHA-256 for hashing instead of Keccak-256, and stores 32-byte stems that map to groups of 256 values. This design simplifies witness generation for stateless clients and enables more efficient proofs.

The transition from MPT to a binary trie is one of the most consequential changes to Ethereum's state layer. Performance characteristics of the new structure will directly affect block processing time, sync speed, and validator economics.

### What is Group Depth?

The trie is **always binary** at the fundamental level -- every internal node has exactly two children (left for bit 0, right for bit 1). Group depth controls how many binary levels are *bundled into a single on-disk node*. At GD-N, each stored node encapsulates an N-level binary subtree, so it *appears* to have 2^N children when viewed from the outside:

- **GD-1:** 1 binary level per node --> 2 child pointers, 256 nodes on the path to a leaf
- **GD-2:** 2 binary levels per node --> 4 child pointers, 128 nodes on path
- **GD-4:** 4 binary levels per node --> 16 child pointers, 64 nodes on path
- **GD-8:** 8 binary levels per node --> 256 child pointers, 32 nodes on path

Think of it like a zip code: GD-1 reads your address one digit at a time (256 steps), while GD-8 reads 8 digits at once (32 steps). Fewer steps means fewer disk reads -- but each "bundled node" is larger and more expensive to update, because the binary subtree inside it must be rehashed.

![Tree Shape Comparison](diagram_1_tree_shapes.png)
<!-- Upload: diagrams/diagram_1_tree_shapes.png -->

*Figure 1 -- Tree shape at different group depths. Each node bundles N binary levels internally, reducing the number of on-disk nodes on the path to a leaf.*

The trade-off is straightforward in theory: reads benefit from shallow trees (fewer disk I/O operations to reach a leaf), while writes suffer from wide nodes (more internal hashing when a node is modified). The question is where the crossover point lies.

---

## S3 -- Methodology

<details>
<summary><strong>Click to expand full methodology</strong></summary>

### Benchmark Setup

| Parameter | Value |
|:----------|:------|
| Machine | QEMU VM -- 8 vCPUs, 30 GB RAM, 3.9 TB SSD, Ubuntu 24.04 LTS |
| Database | ~360 GB, ~400M accounts + storage slots |
| Configurations | GD-1, GD-2, GD-4, GD-8 (Pebble, the LSM-tree storage engine used by geth, 4KB block size) |
| Protocol | Cold cache (OS page cache dropped + Pebble cache=0 between runs) |
| Runs | 10 per benchmark per config; run 1 excluded (residual warmth) |
| Gas target | 100M gas per block |

### Statistical Approach

- Per-run block medians aggregated across 9 retained runs
- **Mann-Whitney U test** for pairwise comparisons (non-parametric)
- Effect sizes reported as percentage difference from baseline (GD-1)
- Coefficient of variation (CV%) for consistency assessment

### Data Completeness

| Benchmark | GD-1 | GD-2 | GD-4 | GD-8 |
|:----------|:-----|:-----|:-----|:-----|
| sload_benchmark | 9 runs | 9 runs | 9 runs | -- |
| sstore_variants | 9 runs | 9 runs | 9 runs | 4 runs |
| erc20_balanceof | 9 runs | 9 runs | 9 runs | 9 runs |
| erc20_approve | 9 runs | 9 runs | 9 runs | 9 runs |
| mixed_sload_sstore | 9 runs | 9 runs | 9 runs | 9 runs |

> **Data gap:** GD-8 synthetic benchmarks (sload_benchmark, sstore_variants) were not completed -- each configuration requires a full 360 GB database rebuild and multi-day benchmark run. We prioritized ERC20 benchmarks because sequential-key synthetic tests showed minimal performance differentiation across group depths, while random-access ERC20 tests exposed the real trade-offs. All ERC20 benchmarks have complete data for all four group depths.

### Benchmark Taxonomy

**a) Synthetic benchmarks** -- `sstore_variants` (writes) and `sload_benchmark` (reads). These use EIP-7702 delegations with sequential storage slots. Keys are numerically sequential, causing heavy prefix sharing in the trie.

**b) ERC20 benchmarks** -- `balanceof` (reads), `approve` (writes), and `mixed`. These use real ERC-20 contract code. Storage keys are keccak hashes of random addresses, producing uniformly distributed access patterns across the trie.

![Sequential vs Random Access Patterns](diagram_2_sequential_vs_random.png)
<!-- Upload: diagrams/diagram_2_sequential_vs_random.png -->

*Figure 2 -- Sequential keys share trie prefixes and benefit from caching. Keccak-hashed keys scatter uniformly, forcing cold reads at every level.*

</details>

---

## S4 -- Act I: Reads Confirm the Intuition

Wider trees should mean faster reads. And they do.

### Synthetic Reads: The Baseline

![Synthetic Read Latency by Group Depth](graphs-light/q1_read_latency_boxplot.png)
<!-- Upload: graphs-light/q1_read_latency_boxplot.png -->

![Per-Block Read Latency Time Series](graphs-light/q1_read_timeseries.png)
<!-- Upload: graphs-light/q1_read_timeseries.png -->

*Per-block read latency for a representative run per config, confirming stable measurements with no degradation over time.*

| Group Depth | Median Read (ms) | vs GD-1 |
|:------------|:-----------------|:--------|
| GD-1 | 53.0 | baseline |
| GD-2 | **48.0** | -9% |
| GD-4 | **47.6** | -10% |
| GD-8 | -- | no data |

Only ~10% improvement from GD-1 to GD-4. Sequential access doesn't differentiate group depths because shared prefixes keep the working set small and cache-friendly regardless of tree shape.

### ERC20 Reads: Where Depth Matters

![ERC20 balanceOf Read Latency by Group Depth](graphs-light/q4_erc20_read_boxplot.png)
<!-- Upload: graphs-light/q4_erc20_read_boxplot.png -->

| GD | state_read (ms) | total (ms) | Mgas/s | vs GD-1 (state_read) |
|:---|:----------------|:-----------|:-------|:--------|
| 1 | 5,878 | 6,284 | 2.65 | baseline |
| 2 | 3,840 | 4,230 | 3.95 | -35% |
| 4 | 2,677 | 3,067 | 5.46 | -54% |
| 8 | **2,598** | **2,977** | **5.59** | **-56%** |

> **56% faster reads.** A 3.3-second reduction per block from GD-1 to GD-8. ERC20 reads expose the full depth penalty because keccak-hashed keys scatter across the entire 256-bit keyspace.

Why the dramatic difference from synthetic? Keccak scatters keys uniformly, forcing a full traversal from root to leaf. GD-1 must descend 256 levels; GD-8 only 32. Every level is a potential disk seek. Random access exposes the full depth penalty: 54% improvement versus 10% for synthetic reads.

Per-slot cost: synthetic reads cost ~0.02 ms/slot. ERC20 reads cost ~0.4--1.0 ms/slot (computed as state_read_ms / storage_slots_read per block) -- a **40x penalty** from random access patterns.

> **Why random access is the baseline, not the exception.** The binary trie unifies all accounts and storage into a single tree. Every key -- whether an account balance, a storage slot, or a code chunk -- is SHA256-hashed into the 256-bit keyspace. A single contract's storage slots scatter across completely different tree paths. This makes random access the *fundamental* access pattern of the binary trie, not a pathological case. The synthetic sequential benchmarks represent an unrealistic best case that cannot occur in a unified trie deployment.

### The Cache Mechanism

![Storage Cache Hit Rate by Group Depth and Benchmark](graphs-light/q7_storage_cache_hit_rates.png)
<!-- Upload: graphs-light/q7_storage_cache_hit_rates.png -->

| Benchmark | GD-1 | GD-2 | GD-4 | GD-8 |
|:----------|:-----|:-----|:-----|:-----|
| sstore | 44.1% | 42.7% | 44.1% | 43.4% |
| sload | 44.2% | 44.4% | 43.9% | -- |
| balanceOf -- reads (ERC20) | 28.1% | 32.8% | **36.7%** | **37.0%** |
| approve -- writes (ERC20) | 25.1% | 30.6% | **35.6%** | **36.3%** |
| mixed | 21.7% | 31.3% | **35.5%** | **38.8%** |

`balanceOf` is a read-only ERC20 function (returns a token balance). `approve` is a write operation (sets a spending allowance, modifying storage). ERC20 is the most common contract type on Ethereum mainnet, making it a representative benchmark target. The ERC20 used here is a minimal implementation -- results indicate clear trends in how group depth affects read vs write performance, though production contracts with more complex storage layouts may show variation.

Two distinct patterns emerge. Synthetic benchmarks: cache rates are flat at ~43--44% regardless of group depth -- sequential access is inherently cache-friendly. ERC20 benchmarks: cache rates **increase by 17 percentage points** from GD-1 (21--28%) to GD-4/8 (35--39%). In shallower trees, upper-level nodes are shared by many keys -- the "shared prefix" effect. But rates plateau at ~39%, as the 256-bit keyspace is too sparse for deeper cache reuse.

*So far, wider is better. GD-8 leads on reads. Then we tested writes.*

---

## S5 -- Act II: The Write Surprise

**This is the most important finding in the study.**

![ERC20 approve Write Cost by Group Depth](graphs-light/q5_erc20_write_boxplot.png)
<!-- Upload: graphs-light/q5_erc20_write_boxplot.png -->

| GD | state_read | trie_updates | commit | Write Cost | Total | Mgas/s |
|:---|:-----------|:-------------|:-------|:-----------|:------|:-------|
| 1 | 812 | 690 | 76 | 762 | 1,645 | 2.67 |
| 2 | 483 | 393 | 61 | 457 | 993 | 4.42 |
| 4 | **313** | **254** | **53** | **308** | **678** | **6.47** |
| 8 | 313 | 433 | 158 | 603 | 982 | 4.47 |

*`trie_updates` = `AccountHashes + AccountUpdates + StorageUpdates` — covers the full trie mutation and rehash phase, not just hashing.*

> **GD-8 writes are 2x slower than GD-4.** Trie updates: +71%. Commit: +198%. The wider tree that wins on reads loses decisively on writes.

The component breakdown tells the story:

- **Reads:** GD-4 and GD-8 are tied at ~313 ms (both excellent)
- **Trie updates:** GD-8 (433 ms) is **71% more expensive** than GD-4 (254 ms)
- **Commit:** GD-8 (158 ms) is **198% more expensive** than GD-4 (53 ms)

The total write cost for GD-8 (603 ms) is nearly **double** GD-4's (308 ms).

### Why? The Internal Subtree

Each trie node at group depth $g$ contains an internal binary subtree with $2^g - 1$ nodes that must be rehashed on every write.

![Internal Subtree Rehashing](diagram_3_internal_subtree.png)
<!-- Upload: diagrams/diagram_3_internal_subtree.png -->

*Figure 3 -- Each trie node contains an internal binary subtree. Wider nodes mean exponentially more hashing per write.*

- **GD-4 node:** 15 internal hash operations x 64 nodes on path = **960 total ops**
- **GD-8 node:** 255 internal hash operations x 32 nodes on path = **8,160 total ops**

GD-8's path is 2x shorter (32 vs 64 levels), but each node is ~17x more expensive to rehash (255 vs 15 internal operations). For reads, only the traversal matters -- GD-8 wins. For writes, rehashing and commit dominate, and the per-node cost overwhelms the shorter path.

> **Note:** The 17× ratio (255 vs 15 internal hash operations) is the theoretical upper bound from the data structure. Our benchmarks support the mechanism: GD-8 trie update costs are 1.71× more than GD-4 (433ms vs 254ms), consistent with random writes modifying a fraction of each node's internal subtree. The geth implementation is the authoritative source for the exact rehashing algorithm.

### Node Serialization Size

Each trie node stores up to 2^N child pointers (32 bytes each). A GD-8 node holds up to 256 × 32 = **~8 KB**. A GD-4 node: 16 × 32 = **~512 bytes**. The 16× size difference has cascading effects:

- **Pebble cache efficiency:** Fewer GD-8 nodes fit in a given cache budget
- **Write amplification:** Larger serialized nodes increase LSM compaction overhead
- **Commit cost:** The 198% commit penalty (158ms vs 53ms) partly reflects serializing 16× more data per modified node

![Read Path vs Write Path](diagram_4_read_vs_write_path.png)
<!-- Upload: diagrams/diagram_4_read_vs_write_path.png -->

*Figure 4 -- For reads, only the downward traversal matters (favors GD-8). For writes, rehashing and commit dominate (favors GD-4). Reads = Step 1 only. Writes = Steps 1 + 2 + 3.*

### Why Synthetic SSTORE Didn't Show This

Sequential slot access clusters writes into the same trie branch, enabling Pebble's write batch to amortize commit costs. The trie update penalty is also reduced because adjacent keys modify the same internal subtrees. The ERC20 benchmark's random access pattern defeated both amortization mechanisms.

![Synthetic Write Cost Boxplot](graphs-light/q2_write_cost_boxplot.png)
<!-- Upload: graphs-light/q2_write_cost_boxplot.png -->

![Trie Update Cost vs Slots Written](graphs-light/q2_write_scaling_scatter.png)
<!-- Upload: graphs-light/q2_write_scaling_scatter.png -->

*Trie update cost scales linearly with slots written. The distinct horizontal bands correspond to different sub-variants. GD-8 points (red) sit slightly above the others at each band.*

Even with sequential access, GD-8 showed a slight elevation in write cost -- a hint of the penalty that ERC20 workloads would expose fully.

---

## S6 -- Act III: The Trade-off

### The Verdict

| Criterion | GD-4 | GD-8 | Winner |
|:----------|:-----|:-----|:-------|
| Reads | 3,067ms | 2,977ms | GD-8 by 3% (p=0.045, borderline) |
| Writes | **678ms** | 982ms | **GD-4 by 45%** (p < 1e-9) |
| Mixed | 2,302ms | 2,145ms | Indistinguishable (p=0.37) |
| Synthetic writes | **91.6ms** | 101.5ms ⚠️ | GD-4 by 10% |

> **3% read sacrifice. 45% write gain.** The asymmetry is decisive. GD-4 trades a borderline-significant read disadvantage for a massively significant write advantage.

### Mixed Workloads

![Mixed Workload Total Block Time](graphs-light/q6_mixed_boxplot.png)
<!-- Upload: graphs-light/q6_mixed_boxplot.png -->

![Mixed Workload Throughput](graphs-light/q6_mixed_mgas.png)
<!-- Upload: graphs-light/q6_mixed_mgas.png -->

| GD | state_read | trie_updates | commit | total_ms | Mgas/s |
|:---|:-----------|:-------------|:-------|:---------|:-------|
| 1 | 4,711 | 345 | 53 | 5,363 | 2.18 |
| 2 | 3,003 | 217 | 44 | 3,518 | 3.35 |
| 4 | 1,893 | **138** | **43** | 2,302 | 5.13 |
| 8 | **1,612** | 221 | 87 | **2,145** | **5.43** |

GD-4 and GD-8 are **statistically indistinguishable** on mixed workloads (Mann-Whitney p=0.37). The read advantage of GD-8 is partially offset by its write penalty, bringing the two configurations to near-parity when reads and writes are interleaved. The crossover depends on the read/write ratio: write-heavy workloads favor GD-4; read-heavy workloads favor GD-8.

> **Open question:** The optimal group depth ultimately depends on the read/write ratio of real Ethereum blocks. While state reads clearly dominate block processing time in our benchmarks, the exact mainnet split has not been systematically measured. A historical analysis of mainnet read vs write access patterns would further inform this recommendation.

The component breakdown reveals the familiar pattern:

- **Reads:** GD-8 wins (1,612 ms vs 1,893 ms) -- shallower tree, fewer I/Os
- **Trie updates:** GD-4 wins (138 ms vs 221 ms) -- smaller internal subtrees
- **Commit:** GD-4 wins (43 ms vs 87 ms) -- less data to serialize

---

## S7 -- Cross-Cutting Patterns

### Where Does Time Go?

![Time Breakdown: Where Does Each Millisecond Go?](graphs-light/q3_erc20_time_breakdown_stacked.png)
<!-- Upload: graphs-light/q3_erc20_time_breakdown_stacked.png -->

![Trie Updates vs Commit Cost by Group Depth](graphs-light/q3_erc20_hash_vs_commit_ratio.png)
<!-- Upload: graphs-light/q3_erc20_hash_vs_commit_ratio.png -->

State reads dominate ERC20 block processing time across all group-depth configurations, accounting for 50--85% of total time. Trie update and commit costs are negligible for read-only benchmarks (balanceOf) but become the dominant cost component for writes (approve) -- especially at higher group depths where internal subtree rehashing is most expensive.

### Overall Throughput

![Overall Throughput by Group Depth](graphs-light/q8_mgas_overview.png)
<!-- Upload: graphs-light/q8_mgas_overview.png -->

---

## S8 -- Conclusions

### Recommendation: GD-4

**GD-4 is the recommended configuration**, with high confidence for ERC20 workloads and moderate confidence for synthetic (pending GD-8 re-run).

The recommendation rests on a three-step mechanism that governs every state access in the binary trie:

1. **Traverse** -- descend from root to leaf. Cost proportional to tree depth. Favors wider trees (GD-8: 32 levels vs GD-4: 64 levels).
2. **Rehash** -- recompute the internal subtree of every node on the path back to root. Cost proportional to $2^g - 1$ per node. Favors narrower trees (GD-4: 15 ops/node vs GD-8: 255 ops/node).
3. **Commit** -- serialize and write modified nodes to disk. Cost proportional to node size. Favors narrower trees.

The math: GD-8 has a 2x shorter path but each node is 17x more expensive to rehash. For reads, only Step 1 matters, and GD-8 wins by 3%. For writes, Steps 2--3 dominate, and GD-4 wins by 45%. The asymmetry is structural and will persist across workloads.

> **GD-8 should be considered** only if the workload is overwhelmingly read-dominated (>90% reads) and writes are rare. For typical Ethereum block processing, GD-4 is the better choice.

### On the Snapshot Layer

These benchmarks ran without a flat snapshot layer. The binary trie already performs efficient path-based reads via Pebble's BTree index -- approaching the read efficiency that MPT achieves only with a snapshot layer. This means the read differences measured here (GD-8 leads GD-4 by only 3%) are close to what real deployments would see. The 45% write penalty of GD-8 remains fully exposed regardless. Snapshots would further favor GD-4 by making its small read disadvantage even more negligible.

### Five Patterns That Hold Across All Group Depths

> **Pattern 1: State reads dominate.** 50--85% of block processing time is spent reading state from disk, regardless of group depth or benchmark type. `state_read_ms` includes account and code lookups in the unified trie, not just storage slot reads.

> **Pattern 2: Random access is ~40x more expensive per slot.** Keccak-hashed keys (ERC20) cost 0.4--1.0 ms/slot vs 0.02 ms/slot for sequential access (synthetic). The gap is driven by Pebble block cache misses on keccak-scattered keys.

> **Pattern 3: Cache hit rates plateau at ~37--39%.** Despite increasing group depth, the storage cache hit rate never exceeds ~39% for keccak-hashed workloads. The 256-bit keyspace is too sparse for meaningful cache reuse beyond shared upper-level trie nodes.

> **Pattern 4: Trie updates are negligible for reads, dominant for writes.** balanceOf (pure reads): trie_updates < 1.3 ms. approve (reads + writes): trie_updates up to 690 ms. This asymmetry means the node-width trade-off only matters for write workloads.

> **Pattern 5: Run-to-run CV < 6%.** Cold-cache protocol and dedicated hardware produce highly reproducible results across all configurations.

### Open Questions

1. **Non-power-of-2 group depths.** We tested GD 1, 2, 4, 8 only. GD-5 (32 children) or GD-6 (64 children) might offer a better read/write trade-off.

2. **Snapshot layer validation.** Empirically confirm that snapshots further favor GD-4 as our analysis predicts.

3. **Pebble block size interaction.** All tests used 4KB blocks. Larger blocks might cache wider nodes more effectively, potentially reducing GD-8's write penalty.

4. **Mainnet state distribution.** Our benchmarks use uniformly distributed random addresses. Real Ethereum state has hot spots (popular DEX contracts, bridges) that might favor different caching behavior.

5. **Concurrent block processing.** These benchmarks process blocks sequentially. Parallel execution engines might amortize trie updates across cores, reducing the per-node rehashing penalty of wider group depths.

6. **GD-8 synthetic re-run.** The sstore_variants (4 runs) and sload_benchmark (0 runs) data for GD-8 needs completion to confirm synthetic findings. ERC20 conclusions are robust.

---

*Benchmarks run on the Ethereum execution-specs framework. Methodology, raw data, and reproducibility scripts available in the [execution-specs repository](https://github.com/ethereum/execution-specs).*

<!--
IMAGE UPLOAD CHECKLIST (16 images):
Diagrams:
- [ ] diagrams/diagram_1_tree_shapes.png
- [ ] diagrams/diagram_2_sequential_vs_random.png
- [ ] diagrams/diagram_3_internal_subtree.png
- [ ] diagrams/diagram_4_read_vs_write_path.png
Data Graphs (light theme):
- [ ] graphs-light/q1_read_latency_boxplot.png
- [ ] graphs-light/q1_read_timeseries.png
- [ ] graphs-light/q2_write_cost_boxplot.png
- [ ] graphs-light/q2_write_scaling_scatter.png
- [ ] graphs-light/q3_erc20_time_breakdown_stacked.png
- [ ] graphs-light/q3_erc20_hash_vs_commit_ratio.png
- [ ] graphs-light/q4_erc20_read_boxplot.png
- [ ] graphs-light/q5_erc20_write_boxplot.png
- [ ] graphs-light/q6_mixed_boxplot.png
- [ ] graphs-light/q6_mixed_mgas.png
- [ ] graphs-light/q7_storage_cache_hit_rates.png
- [ ] graphs-light/q8_mgas_overview.png
-->
