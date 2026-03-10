# Binary Trie Benchmarks

Performance benchmarks for Ethereum's binary trie implementation ([EIP-7864](https://eips.ethereum.org/EIPS/eip-7864)).

## Experiments

### [Group Depth Benchmarks](group-depth-benchmarks/)

Compared four group-depth configurations (GD-1, GD-2, GD-4, GD-8) on 360 GB databases with ~400M state entries. Five benchmark types -- two synthetic (sequential SLOAD/SSTORE) and three ERC20 contract workloads (balanceOf, approve, mixed) -- each run 10 times under a cold-cache protocol on a dedicated QEMU VM (8 vCPUs, 30 GB RAM, 3.9 TB SSD).

**Result:** GD-4 is optimal. Reads are statistically identical to GD-8 (3% difference, p=0.045 borderline), but writes are **45% faster** (p < 1e-9). The asymmetry is structural: each GD-8 node contains 255 internal nodes to rehash on write vs 15 for GD-4 -- a 17x per-node cost that overwhelms the 2x shorter traversal path.

[Full report](group-depth-benchmarks/index.html) ·
[ethresear.ch post](group-depth-benchmarks/ethresearch-post.md) ·
[Raw data](group-depth-benchmarks/data/)
