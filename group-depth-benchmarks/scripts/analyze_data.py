#!/usr/bin/env python3
"""
Statistical analysis of group-depth benchmark data.

Reads all bt-gd*_all_benchmarks.csv files from data/ and outputs:
- Per-benchmark median tables (blocks with gas > 500K, excluding run 1)
- Mann-Whitney U pairwise p-values
- CV% per config per benchmark
- Percentage diffs relative to GD-1 and GD-4

Usage:
    python scripts/analyze_data.py [--data-dir data/]
"""

import argparse
import csv
import sys
from pathlib import Path
from collections import defaultdict
import statistics

try:
    from scipy.stats import mannwhitneyu
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False


ERC20_BENCHMARKS = ["erc20_balanceof", "erc20_approve", "mixed_sload_sstore"]
TIMING_COLS = ["state_read_ms", "state_hash_ms", "commit_ms", "total_ms", "mgas_per_sec"]
GROUP_DEPTHS = [1, 2, 3, 4, 5, 6, 8]


def load_data(data_dir):
    """Load all benchmark CSVs into {gd: {benchmark: [rows]}}."""
    data = defaultdict(lambda: defaultdict(list))
    for gd in GROUP_DEPTHS:
        csv_path = data_dir / f"bt-gd{gd}_all_benchmarks.csv"
        if not csv_path.exists():
            print(f"  WARNING: {csv_path} not found, skipping GD-{gd}")
            continue
        with open(csv_path, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                bench = row["benchmark"]
                gas = int(row["gas_used"])
                run = int(row["run"])
                # Filter: gas > 500K (real benchmark blocks) and run > 1 (skip warmup)
                if gas > 500000 and run > 1:
                    data[gd][bench].append(row)
    return data


def get_values(rows, col):
    """Extract float values for a column from rows."""
    return [float(r[col]) for r in rows]


def median(vals):
    if not vals:
        return 0
    return statistics.median(vals)


def cv_percent(vals):
    if len(vals) < 2:
        return 0
    m = statistics.mean(vals)
    if m == 0:
        return 0
    return 100 * statistics.stdev(vals) / m


def print_separator(char="=", width=100):
    print(char * width)


def main():
    parser = argparse.ArgumentParser(description="Analyze group-depth benchmark data")
    parser.add_argument("--data-dir", default="data/", help="Directory with CSV files")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    data = load_data(data_dir)

    if not data:
        print("ERROR: No data loaded.")
        sys.exit(1)

    # =========================================================================
    # 1. Per-benchmark median table
    # =========================================================================
    print_separator()
    print("  MEDIAN TIMING TABLE (blocks with gas > 500K, excluding run 1)")
    print_separator()

    for bench in ERC20_BENCHMARKS:
        print(f"\n--- {bench} ---")
        header = f"{'GD':>4} {'Runs':>5} {'Blocks':>7}"
        for col in TIMING_COLS:
            header += f" {col:>16}"
        print(header)
        print("-" * len(header))

        for gd in GROUP_DEPTHS:
            rows = data[gd].get(bench, [])
            if not rows:
                print(f"{gd:>4} {'--':>5} {'--':>7}" + "".join(f" {'--':>16}" for _ in TIMING_COLS))
                continue
            runs = len(set(int(r["run"]) for r in rows))
            line = f"{gd:>4} {runs:>5} {len(rows):>7}"
            for col in TIMING_COLS:
                vals = get_values(rows, col)
                line += f" {median(vals):>16.2f}"
            print(line)

    # =========================================================================
    # 2. Percentage differences relative to GD-4
    # =========================================================================
    print()
    print_separator()
    print("  PERCENTAGE DIFF vs GD-4 (median total_ms)")
    print_separator()

    for bench in ERC20_BENCHMARKS:
        print(f"\n--- {bench} ---")
        gd4_rows = data[4].get(bench, [])
        if not gd4_rows:
            print("  GD-4 data missing")
            continue
        gd4_median = median(get_values(gd4_rows, "total_ms"))

        for gd in GROUP_DEPTHS:
            rows = data[gd].get(bench, [])
            if not rows:
                print(f"  GD-{gd}: no data")
                continue
            gd_median = median(get_values(rows, "total_ms"))
            pct = 100 * (gd_median - gd4_median) / gd4_median if gd4_median else 0
            sign = "+" if pct > 0 else ""
            runs = len(set(int(r["run"]) for r in rows))
            flag = " (preliminary, n=2)" if runs <= 2 else ""
            print(f"  GD-{gd}: {gd_median:>8.1f} ms ({sign}{pct:>+6.1f}%){flag}")

    # =========================================================================
    # 3. CV% (coefficient of variation)
    # =========================================================================
    print()
    print_separator()
    print("  COEFFICIENT OF VARIATION (CV%) — total_ms")
    print_separator()

    for bench in ERC20_BENCHMARKS:
        print(f"\n--- {bench} ---")
        for gd in GROUP_DEPTHS:
            rows = data[gd].get(bench, [])
            if not rows:
                continue
            vals = get_values(rows, "total_ms")
            cv = cv_percent(vals)
            print(f"  GD-{gd}: CV = {cv:.1f}% (n={len(vals)})")

    # =========================================================================
    # 4. Mann-Whitney U pairwise p-values
    # =========================================================================
    if HAS_SCIPY:
        print()
        print_separator()
        print("  MANN-WHITNEY U PAIRWISE COMPARISONS — total_ms")
        print_separator()

        pairs = [
            (3, 4), (4, 5), (4, 6), (5, 6), (5, 8), (6, 8),
            (1, 4), (2, 4), (4, 8),
        ]

        for bench in ERC20_BENCHMARKS:
            print(f"\n--- {bench} ---")
            for gd_a, gd_b in pairs:
                rows_a = data[gd_a].get(bench, [])
                rows_b = data[gd_b].get(bench, [])
                if not rows_a or not rows_b:
                    print(f"  GD-{gd_a} vs GD-{gd_b}: insufficient data")
                    continue
                vals_a = get_values(rows_a, "total_ms")
                vals_b = get_values(rows_b, "total_ms")
                stat, p = mannwhitneyu(vals_a, vals_b, alternative="two-sided")
                med_a = median(vals_a)
                med_b = median(vals_b)
                diff = 100 * (med_b - med_a) / med_a if med_a else 0
                sig = "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "ns"
                print(f"  GD-{gd_a} vs GD-{gd_b}: "
                      f"median {med_a:.1f} vs {med_b:.1f} ms "
                      f"(diff: {diff:+.1f}%), p={p:.2e} {sig}")

        # Also compare state_hash_ms and commit_ms for write benchmark
        print()
        print_separator()
        print("  MANN-WHITNEY U — state_hash_ms (erc20_approve)")
        print_separator()
        bench = "erc20_approve"
        for gd_a, gd_b in pairs:
            rows_a = data[gd_a].get(bench, [])
            rows_b = data[gd_b].get(bench, [])
            if not rows_a or not rows_b:
                continue
            for col in ["state_hash_ms", "commit_ms"]:
                vals_a = get_values(rows_a, col)
                vals_b = get_values(rows_b, col)
                stat, p = mannwhitneyu(vals_a, vals_b, alternative="two-sided")
                med_a = median(vals_a)
                med_b = median(vals_b)
                diff = 100 * (med_b - med_a) / med_a if med_a else 0
                sig = "***" if p < 0.001 else "**" if p < 0.01 else "*" if p < 0.05 else "ns"
                print(f"  GD-{gd_a} vs GD-{gd_b} [{col}]: "
                      f"{med_a:.1f} vs {med_b:.1f} ms ({diff:+.1f}%), p={p:.2e} {sig}")
    else:
        print("\n  scipy not available — skipping Mann-Whitney U tests")
        print("  Install with: pip install scipy")

    # =========================================================================
    # 5. Summary: Best config per benchmark
    # =========================================================================
    print()
    print_separator()
    print("  SUMMARY: BEST CONFIG PER BENCHMARK (lowest median total_ms)")
    print_separator()

    for bench in ERC20_BENCHMARKS:
        best_gd = None
        best_median = float("inf")
        for gd in GROUP_DEPTHS:
            rows = data[gd].get(bench, [])
            if not rows:
                continue
            med = median(get_values(rows, "total_ms"))
            if med < best_median:
                best_median = med
                best_gd = gd
        if best_gd is not None:
            print(f"  {bench}: GD-{best_gd} ({best_median:.1f} ms)")

    # =========================================================================
    # 6. Hash vs commit breakdown for writes
    # =========================================================================
    print()
    print_separator()
    print("  HASH vs COMMIT BREAKDOWN (erc20_approve)")
    print_separator()
    bench = "erc20_approve"
    print(f"{'GD':>4} {'hash_ms':>10} {'commit_ms':>10} {'ratio h/c':>10} {'total_ms':>10}")
    for gd in GROUP_DEPTHS:
        rows = data[gd].get(bench, [])
        if not rows:
            print(f"{gd:>4} {'--':>10} {'--':>10} {'--':>10} {'--':>10}")
            continue
        h = median(get_values(rows, "state_hash_ms"))
        c = median(get_values(rows, "commit_ms"))
        t = median(get_values(rows, "total_ms"))
        ratio = h / c if c > 0 else 0
        print(f"{gd:>4} {h:>10.1f} {c:>10.1f} {ratio:>10.2f} {t:>10.1f}")


if __name__ == "__main__":
    main()
