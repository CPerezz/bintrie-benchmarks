# Group Depth Benchmarks

Performance comparison of four binary trie group-depth configurations (GD-1, GD-2, GD-4, GD-8) on the geth implementation.

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
