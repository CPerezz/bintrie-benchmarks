#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["matplotlib"]
# ///
"""
Generate 16 benchmark visualization PNGs for binary trie group-depth comparison.

Usage:
    python scripts/generate_graphs.py --output-dir graphs --theme dark
    python scripts/generate_graphs.py --output-dir graphs-light --theme light
    uv run --with matplotlib scripts/generate_graphs.py
"""
from __future__ import annotations

import argparse
import csv
import math
import os
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.ticker as mticker


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GD_ORDER: list[int] = [1, 2, 3, 4, 5, 6, 8]

COLORS: dict[int, str] = {
    1: '#1f77b4',  # blue
    2: '#ff7f0e',  # orange
    3: '#9467bd',  # purple
    4: '#2ca02c',  # green
    5: '#17becf',  # cyan
    6: '#e377c2',  # pink
    8: '#d62728',  # red
}

# Configs that only have synthetic benchmark data (no ERC20)
READ_ONLY_GDS: list[int] = [1, 2, 4]       # q1: no GD-8 data for sload
WRITE_GDS: list[int] = [1, 2, 4, 8]        # q2: synthetic write configs

FIGSIZE = (10, 6)

ERC20_BENCHMARKS = ["erc20_balanceof", "erc20_approve", "mixed_sload_sstore"]

STACKED_COMPONENTS = ["state_read_ms", "execution_ms", "state_hash_ms", "commit_ms"]
STACKED_LABELS = ["State Read", "Execution", "State Hash", "Commit"]
STACKED_COLORS_DARK = ["#1f77b4", "#888888", "#ff7f0e", "#d62728"]


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------

class Theme:
    def __init__(self, name: str, bg: str, text: str, grid: str, axes: str) -> None:
        self.name = name
        self.bg = bg
        self.text = text
        self.grid = grid
        self.axes = axes

    def apply(self) -> None:
        plt.rcParams.update({
            "figure.facecolor": self.bg,
            "axes.facecolor": self.bg,
            "axes.edgecolor": self.axes,
            "axes.labelcolor": self.text,
            "text.color": self.text,
            "xtick.color": self.text,
            "ytick.color": self.text,
            "grid.color": self.grid,
            "legend.facecolor": self.bg,
            "legend.edgecolor": self.axes,
            "legend.labelcolor": self.text,
        })


THEMES: dict[str, Theme] = {
    "dark": Theme(
        name="dark",
        bg="#0A0E17",
        text="#E2E8F0",
        grid="#1E293B",
        axes="#475569",
    ),
    "light": Theme(
        name="light",
        bg="#FFFFFF",
        text="#1E293B",
        grid="#E2E8F0",
        axes="#94A3B8",
    ),
}


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_data(data_dir: Path) -> dict[int, list[dict[str, Any]]]:
    """Load bt-gd{N}_all_benchmarks.csv for each N, return dict keyed by GD.

    Applies filters: gas_used > 500000 and run > 1 (exclude warmup).
    """
    all_data: dict[int, list[dict[str, Any]]] = {}
    float_cols = [
        "gas_used", "execution_ms", "state_read_ms", "state_hash_ms",
        "commit_ms", "total_ms", "mgas_per_sec",
        "account_cache_hit_rate", "storage_cache_hit_rate",
        "code_cache_hit_rate",
    ]
    int_cols = [
        "group_depth", "run", "block_number", "tx_count",
        "accounts_read", "storage_slots_read", "code_read",
        "accounts_written", "storage_slots_written",
        "storage_slots_deleted", "code_written",
    ]

    for gd in GD_ORDER:
        fpath = data_dir / f"bt-gd{gd}_all_benchmarks.csv"
        if not fpath.exists():
            print(f"  WARNING: {fpath} not found, skipping GD-{gd}", file=sys.stderr)
            continue
        rows: list[dict[str, Any]] = []
        with open(fpath, newline="") as f:
            reader = csv.DictReader(f)
            for r in reader:
                run = int(r["run"])
                gas = float(r["gas_used"])
                if gas <= 500_000 or run <= 1:
                    continue
                row: dict[str, Any] = dict(r)
                for c in float_cols:
                    if c in row:
                        row[c] = float(row[c])
                for c in int_cols:
                    if c in row:
                        row[c] = int(row[c])
                rows.append(row)
        all_data[gd] = rows
        print(f"  GD-{gd}: {len(rows)} rows loaded")
    return all_data


def filter_benchmark(all_data: dict[int, list[dict]], benchmark: str,
                     gd_list: list[int] | None = None) -> dict[int, list[dict]]:
    """Filter data for a specific benchmark, returning {gd: [rows]}."""
    if gd_list is None:
        gd_list = GD_ORDER
    result: dict[int, list[dict]] = {}
    for gd in gd_list:
        if gd not in all_data:
            continue
        matched = [r for r in all_data[gd] if r["benchmark"] == benchmark]
        if matched:
            result[gd] = matched
    return result


def col_values(rows: list[dict], col: str) -> list[float]:
    """Extract a column as list of floats."""
    return [row[col] for row in rows]


def median_val(values: list[float]) -> float:
    if not values:
        return 0.0
    return statistics.median(values)


def cv_percent(values: list[float]) -> float:
    """Coefficient of variation as percentage."""
    if len(values) < 2:
        return 0.0
    m = statistics.mean(values)
    if m == 0:
        return 0.0
    s = statistics.stdev(values)
    return (s / m) * 100.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def gd_label(gd: int) -> str:
    return f"GD-{gd}"


def gd_labels(gd_list: list[int]) -> list[str]:
    return [gd_label(gd) for gd in gd_list]


def save_fig(fig: plt.Figure, output_dir: Path, name: str, dpi: int) -> None:
    path = output_dir / name
    fig.savefig(path, dpi=dpi, bbox_inches="tight", facecolor=fig.get_facecolor())
    plt.close(fig)
    print(f"  -> {path}")


def make_boxplot(ax: plt.Axes, data_list: list[list[float]], labels: list[str],
                 colors: list[str], theme: Theme, star_idx: int | None = None) -> None:
    """Draw styled boxplots with median annotations.

    star_idx: if set, add a star marker on that box (0-indexed).
    """
    if not data_list:
        return
    med_color = "white" if theme.name == "dark" else "black"
    bp = ax.boxplot(
        data_list, labels=labels, patch_artist=True,
        medianprops=dict(color=med_color, linewidth=1.5),
        whiskerprops=dict(color=theme.text, linewidth=0.8),
        capprops=dict(color=theme.text, linewidth=0.8),
        flierprops=dict(marker="o", markersize=3, alpha=0.4,
                        markerfacecolor=theme.text, markeredgecolor="none"),
    )
    for i, (patch, color) in enumerate(zip(bp["boxes"], colors)):
        patch.set_facecolor(color)
        patch.set_alpha(0.7)
        patch.set_edgecolor(theme.text)

    # Annotate medians
    for i, d in enumerate(data_list):
        if not d:
            continue
        med = median_val(d)
        ax.text(i + 1, med, f"{med:.1f}", ha="center", va="bottom",
                fontsize=7, fontweight="bold", color=theme.text,
                bbox=dict(boxstyle="round,pad=0.15",
                          fc=theme.bg, alpha=0.7, edgecolor="none"))

    # Star annotation on winner
    if star_idx is not None and 0 <= star_idx < len(data_list):
        d = data_list[star_idx]
        if d:
            med = median_val(d)
            ax.plot(star_idx + 1, med * 1.15, marker="*", markersize=14,
                    color="#FFD700", zorder=10, markeredgecolor="black",
                    markeredgewidth=0.5)


def add_star_to_bar(ax: plt.Axes, bar_obj, idx: int) -> None:
    """Add a gold star above a specific bar."""
    rect = bar_obj[idx]
    cx = rect.get_x() + rect.get_width() / 2
    top = rect.get_height()
    ax.plot(cx, top * 1.05, marker="*", markersize=14, color="#FFD700",
            zorder=10, markeredgecolor="black", markeredgewidth=0.5)


# ---------------------------------------------------------------------------
# Graph generators
# ---------------------------------------------------------------------------

def q1_read_latency_boxplot(all_data: dict, theme: Theme,
                            output_dir: Path, dpi: int) -> None:
    """Synthetic read latency boxplot (GD-1, 2, 4 only)."""
    by_gd = filter_benchmark(all_data, "sload_benchmark", READ_ONLY_GDS)
    gds = [gd for gd in READ_ONLY_GDS if gd in by_gd]
    if not gds:
        print("  SKIP q1_read_latency_boxplot: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    data = [col_values(by_gd[gd], "total_ms") for gd in gds]
    colors = [COLORS[gd] for gd in gds]
    labels = gd_labels(gds)
    make_boxplot(ax, data, labels, colors, theme)
    ax.set_title("Synthetic Read Latency (sload_benchmark)", fontsize=13, fontweight="bold")
    ax.set_ylabel("total_ms")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, output_dir, "q1_read_latency_boxplot.png", dpi)


def q1_read_timeseries(all_data: dict, theme: Theme,
                       output_dir: Path, dpi: int) -> None:
    """Per-block read time series for sload_benchmark, run 2 only."""
    by_gd = filter_benchmark(all_data, "sload_benchmark", READ_ONLY_GDS)
    gds = [gd for gd in READ_ONLY_GDS if gd in by_gd]
    if not gds:
        print("  SKIP q1_read_timeseries: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    for gd in gds:
        run2 = [r for r in by_gd[gd] if r["run"] == 2]
        if not run2:
            # Fall back to first available run
            runs = sorted({r["run"] for r in by_gd[gd]})
            if runs:
                run2 = [r for r in by_gd[gd] if r["run"] == runs[0]]
        if not run2:
            continue
        run2.sort(key=lambda r: r["block_number"])
        x = list(range(len(run2)))
        y = [r["total_ms"] for r in run2]
        ax.plot(x, y, label=gd_label(gd), color=COLORS[gd],
                alpha=0.8, linewidth=1.2, marker=".", markersize=3)
    ax.set_title("Per-Block Read Time Series (sload_benchmark, run 2)",
                 fontsize=13, fontweight="bold")
    ax.set_ylabel("total_ms")
    ax.set_xlabel("Block Index")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "q1_read_timeseries.png", dpi)


def q2_write_cost_boxplot(all_data: dict, theme: Theme,
                          output_dir: Path, dpi: int) -> None:
    """Synthetic write cost boxplot (GD-1,2,4,8)."""
    by_gd = filter_benchmark(all_data, "sstore_variants", WRITE_GDS)
    gds = [gd for gd in WRITE_GDS if gd in by_gd]
    if not gds:
        print("  SKIP q2_write_cost_boxplot: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    data = [col_values(by_gd[gd], "total_ms") for gd in gds]
    colors = [COLORS[gd] for gd in gds]
    labels = gd_labels(gds)
    # GD-5 is not in WRITE_GDS, so no star here
    make_boxplot(ax, data, labels, colors, theme)
    ax.set_title("Synthetic Write Cost (sstore_variants)", fontsize=13, fontweight="bold")
    ax.set_ylabel("total_ms")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, output_dir, "q2_write_cost_boxplot.png", dpi)


def q2_write_scaling_scatter(all_data: dict, theme: Theme,
                             output_dir: Path, dpi: int) -> None:
    """Trie update cost vs slots written scatter for sstore_variants."""
    by_gd = filter_benchmark(all_data, "sstore_variants", WRITE_GDS)
    gds = [gd for gd in WRITE_GDS if gd in by_gd]
    if not gds:
        print("  SKIP q2_write_scaling_scatter: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    for gd in gds:
        x = col_values(by_gd[gd], "storage_slots_written")
        y = col_values(by_gd[gd], "state_hash_ms")
        ax.scatter(x, y, label=gd_label(gd), color=COLORS[gd],
                   alpha=0.6, s=25, edgecolors="none")
    ax.set_title("Trie Update Cost vs Slots Written (sstore_variants)",
                 fontsize=13, fontweight="bold")
    ax.set_ylabel("state_hash_ms")
    ax.set_xlabel("storage_slots_written")
    ax.grid(alpha=0.3)
    ax.legend(fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "q2_write_scaling_scatter.png", dpi)


def q3_erc20_time_breakdown_stacked(all_data: dict, theme: Theme,
                                    output_dir: Path, dpi: int) -> None:
    """ERC20 time breakdown stacked bar, 3 subplot rows, all 7 configs."""
    benchmarks = ["erc20_balanceof", "erc20_approve", "mixed_sload_sstore"]
    titles = ["ERC20 balanceOf", "ERC20 approve", "ERC20 mixed"]

    fig, axes = plt.subplots(3, 1, figsize=(10, 14))
    for idx, (bench, title) in enumerate(zip(benchmarks, titles)):
        ax = axes[idx]
        by_gd = filter_benchmark(all_data, bench, GD_ORDER)
        gds = [gd for gd in GD_ORDER if gd in by_gd]
        if not gds:
            ax.set_title(f"{title} (no data)", fontsize=11)
            continue

        x = list(range(len(gds)))
        width = 0.6
        bottoms = [0.0] * len(gds)

        for comp, label, color in zip(STACKED_COMPONENTS, STACKED_LABELS,
                                       STACKED_COLORS_DARK):
            vals = [median_val(col_values(by_gd[gd], comp)) for gd in gds]
            ax.bar(x, vals, width, bottom=bottoms, label=label,
                   color=color, alpha=0.85, edgecolor=theme.axes, linewidth=0.5)
            # Annotate each segment
            for i, (v, b) in enumerate(zip(vals, bottoms)):
                if v > 0.5:
                    text_color = "white" if theme.name == "dark" else "black"
                    ax.text(i, b + v / 2, f"{v:.1f}", ha="center", va="center",
                            fontsize=6, color=text_color, fontweight="bold")
            bottoms = [b + v for b, v in zip(bottoms, vals)]

        ax.set_xticks(x)
        ax.set_xticklabels(gd_labels(gds), fontsize=9)
        ax.set_title(title, fontsize=12, fontweight="bold")
        ax.set_ylabel("Median ms")
        ax.grid(axis="y", alpha=0.3)
        if idx == 0:
            ax.legend(fontsize=8, loc="upper left")

    fig.suptitle("ERC20 Time Breakdown (Stacked, Median)", fontsize=14, fontweight="bold")
    fig.tight_layout(rect=[0, 0, 1, 0.96])
    save_fig(fig, output_dir, "q3_erc20_time_breakdown_stacked.png", dpi)


def q3_erc20_hash_vs_commit_ratio(all_data: dict, theme: Theme,
                                  output_dir: Path, dpi: int) -> None:
    """Side-by-side bar chart: median state_hash_ms and commit_ms for erc20_approve."""
    by_gd = filter_benchmark(all_data, "erc20_approve", GD_ORDER)
    gds = [gd for gd in GD_ORDER if gd in by_gd]
    if not gds:
        print("  SKIP q3_erc20_hash_vs_commit_ratio: no data")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)
    x = list(range(len(gds)))
    width = 0.35

    hash_vals = [median_val(col_values(by_gd[gd], "state_hash_ms")) for gd in gds]
    commit_vals = [median_val(col_values(by_gd[gd], "commit_ms")) for gd in gds]

    x_hash = [xi - width / 2 for xi in x]
    x_commit = [xi + width / 2 for xi in x]

    bars_h = ax.bar(x_hash, hash_vals, width, label="state_hash_ms",
                    color="#ff7f0e", alpha=0.85, edgecolor=theme.axes, linewidth=0.5)
    bars_c = ax.bar(x_commit, commit_vals, width, label="commit_ms",
                    color="#d62728", alpha=0.85, edgecolor=theme.axes, linewidth=0.5)

    for bars in [bars_h, bars_c]:
        for bar in bars:
            h = bar.get_height()
            if h > 0:
                ax.text(bar.get_x() + bar.get_width() / 2, h,
                        f"{h:.1f}", ha="center", va="bottom",
                        fontsize=7, color=theme.text, fontweight="bold")

    # Star on GD-5
    if 5 in gds:
        idx5 = gds.index(5)
        top_val = max(hash_vals[idx5], commit_vals[idx5])
        ax.plot(x[idx5], top_val * 1.12, marker="*", markersize=14,
                color="#FFD700", zorder=10, markeredgecolor="black",
                markeredgewidth=0.5)

    ax.set_xticks(x)
    ax.set_xticklabels(gd_labels(gds))
    ax.set_title("Trie Updates vs Commit — erc20_approve", fontsize=13, fontweight="bold")
    ax.set_ylabel("Median ms")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=9)
    fig.tight_layout()
    save_fig(fig, output_dir, "q3_erc20_hash_vs_commit_ratio.png", dpi)


def q4_erc20_read_boxplot(all_data: dict, theme: Theme,
                          output_dir: Path, dpi: int) -> None:
    """ERC20 balanceOf read throughput boxplot (mgas_per_sec), all 7 configs."""
    by_gd = filter_benchmark(all_data, "erc20_balanceof", GD_ORDER)
    gds = [gd for gd in GD_ORDER if gd in by_gd]
    if not gds:
        print("  SKIP q4_erc20_read_boxplot: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    data = [col_values(by_gd[gd], "mgas_per_sec") for gd in gds]
    colors = [COLORS[gd] for gd in gds]
    labels = gd_labels(gds)
    make_boxplot(ax, data, labels, colors, theme)
    ax.set_title("ERC20 Read Throughput by Group Depth", fontsize=13, fontweight="bold")
    ax.set_ylabel("Throughput (Mgas/s)")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, output_dir, "q4_erc20_read_boxplot.png", dpi)


def q5_erc20_write_boxplot(all_data: dict, theme: Theme,
                           output_dir: Path, dpi: int) -> None:
    """ERC20 approve write cost boxplot (total_ms), all 7 configs."""
    by_gd = filter_benchmark(all_data, "erc20_approve", GD_ORDER)
    gds = [gd for gd in GD_ORDER if gd in by_gd]
    if not gds:
        print("  SKIP q5_erc20_write_boxplot: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    data = [col_values(by_gd[gd], "total_ms") for gd in gds]
    colors = [COLORS[gd] for gd in gds]
    labels = gd_labels(gds)
    # Star on GD-5
    star_idx = gds.index(5) if 5 in gds else None
    make_boxplot(ax, data, labels, colors, theme, star_idx=star_idx)
    ax.set_title("ERC20 Write Cost — erc20_approve", fontsize=13, fontweight="bold")
    ax.set_ylabel("total_ms")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, output_dir, "q5_erc20_write_boxplot.png", dpi)


def q6_mixed_boxplot(all_data: dict, theme: Theme,
                     output_dir: Path, dpi: int) -> None:
    """Mixed workload boxplot (total_ms), all 7 configs."""
    by_gd = filter_benchmark(all_data, "mixed_sload_sstore", GD_ORDER)
    gds = [gd for gd in GD_ORDER if gd in by_gd]
    if not gds:
        print("  SKIP q6_mixed_boxplot: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    data = [col_values(by_gd[gd], "total_ms") for gd in gds]
    colors = [COLORS[gd] for gd in gds]
    labels = gd_labels(gds)
    make_boxplot(ax, data, labels, colors, theme)
    ax.set_title("Mixed Workload — mixed_sload_sstore", fontsize=13, fontweight="bold")
    ax.set_ylabel("total_ms")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, output_dir, "q6_mixed_boxplot.png", dpi)


def q6_mixed_mgas(all_data: dict, theme: Theme,
                  output_dir: Path, dpi: int) -> None:
    """Mixed throughput bar chart (median mgas_per_sec), all 7 configs."""
    by_gd = filter_benchmark(all_data, "mixed_sload_sstore", GD_ORDER)
    gds = [gd for gd in GD_ORDER if gd in by_gd]
    if not gds:
        print("  SKIP q6_mixed_mgas: no data")
        return
    fig, ax = plt.subplots(figsize=FIGSIZE)
    medians = [median_val(col_values(by_gd[gd], "mgas_per_sec")) for gd in gds]
    bars = ax.bar(gd_labels(gds), medians,
                  color=[COLORS[gd] for gd in gds], alpha=0.85,
                  edgecolor=theme.axes, linewidth=0.5)
    for bar, val in zip(bars, medians):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height(),
                f"{val:.1f}", ha="center", va="bottom",
                fontsize=8, color=theme.text, fontweight="bold")
    ax.set_title("Mixed Throughput — mixed_sload_sstore", fontsize=13, fontweight="bold")
    ax.set_ylabel("Median Mgas/s")
    ax.set_xlabel("Group Depth")
    ax.grid(axis="y", alpha=0.3)
    fig.tight_layout()
    save_fig(fig, output_dir, "q6_mixed_mgas.png", dpi)


def q7_account_cache_hit_rates(all_data: dict, theme: Theme,
                               output_dir: Path, dpi: int) -> None:
    """Account cache hit rate grouped bar chart, all benchmarks by GD."""
    _cache_hit_rate_chart(all_data, theme, output_dir, dpi,
                          "account_cache_hit_rate",
                          "Account Cache Hit Rate by Benchmark & Group Depth",
                          "q7_account_cache_hit_rates.png")


def q7_storage_cache_hit_rates(all_data: dict, theme: Theme,
                               output_dir: Path, dpi: int) -> None:
    """Storage cache hit rate grouped bar chart, all benchmarks by GD."""
    _cache_hit_rate_chart(all_data, theme, output_dir, dpi,
                          "storage_cache_hit_rate",
                          "Storage Cache Hit Rate by Benchmark & Group Depth",
                          "q7_storage_cache_hit_rates.png")


def _cache_hit_rate_chart(all_data: dict, theme: Theme, output_dir: Path,
                          dpi: int, attr: str, title: str, filename: str) -> None:
    """Grouped bar chart: for each benchmark, show cache hit rate median per GD."""
    all_benchmarks = sorted({
        r["benchmark"]
        for rows in all_data.values()
        for r in rows
    })
    if not all_benchmarks:
        print(f"  SKIP {filename}: no data")
        return

    fig, ax = plt.subplots(figsize=(12, 6))
    n_bench = len(all_benchmarks)
    n_gd = len(GD_ORDER)
    total_width = 0.75
    bar_width = total_width / n_gd

    for gd_idx, gd in enumerate(GD_ORDER):
        vals = []
        has_any = False
        for bench in all_benchmarks:
            by_gd = filter_benchmark(all_data, bench, [gd])
            if gd in by_gd:
                vals.append(median_val(col_values(by_gd[gd], attr)))
                has_any = True
            else:
                vals.append(None)
        if not has_any:
            continue
        offset = (gd_idx - n_gd / 2 + 0.5) * bar_width
        x_pos = [i + offset for i in range(n_bench)]
        bar_vals = [v if v is not None else 0 for v in vals]
        bars = ax.bar(x_pos, bar_vals, bar_width, label=gd_label(gd),
                      color=COLORS[gd], alpha=0.8, edgecolor=theme.axes, linewidth=0.3)
        for i, v in enumerate(vals):
            if v is None:
                bars[i].set_visible(False)

    ax.set_xticks(range(n_bench))
    ax.set_xticklabels([b.replace("_", "\n") for b in all_benchmarks],
                       fontsize=7, ha="center")
    ax.set_title(title, fontsize=13, fontweight="bold")
    ax.set_ylabel("Cache Hit Rate (%)")
    ax.set_ylim(0, 105)
    ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=7, ncol=4, loc="lower right")
    fig.tight_layout()
    save_fig(fig, output_dir, filename, dpi)


def q8_mgas_overview(all_data: dict, theme: Theme,
                     output_dir: Path, dpi: int) -> None:
    """Grouped bar chart: median mgas_per_sec per GD for each ERC20 benchmark."""
    benchmarks = ERC20_BENCHMARKS
    active = []
    for bench in benchmarks:
        by_gd = filter_benchmark(all_data, bench, GD_ORDER)
        if by_gd:
            active.append(bench)
    if not active:
        print("  SKIP q8_mgas_overview: no data")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)
    n_bench = len(active)
    n_gd = len(GD_ORDER)
    total_width = 0.75
    bar_width = total_width / n_gd

    for gd_idx, gd in enumerate(GD_ORDER):
        vals = []
        has_any = False
        for bench in active:
            by_gd = filter_benchmark(all_data, bench, [gd])
            if gd in by_gd:
                vals.append(median_val(col_values(by_gd[gd], "mgas_per_sec")))
                has_any = True
            else:
                vals.append(None)
        if not has_any:
            continue
        offset = (gd_idx - n_gd / 2 + 0.5) * bar_width
        x_pos = [i + offset for i in range(n_bench)]
        bar_vals = [v if v is not None else 0 for v in vals]
        bars = ax.bar(x_pos, bar_vals, bar_width, label=gd_label(gd),
                      color=COLORS[gd], alpha=0.8, edgecolor=theme.axes, linewidth=0.3)
        for i, v in enumerate(vals):
            if v is None:
                bars[i].set_visible(False)

    ax.set_xticks(range(n_bench))
    ax.set_xticklabels([b.replace("_", "\n") for b in active], fontsize=9)
    ax.set_title("Overall Throughput by Benchmark & Group Depth",
                 fontsize=13, fontweight="bold")
    ax.set_ylabel("Median Mgas/s")
    ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=7, ncol=4, loc="upper right")
    fig.tight_layout()
    save_fig(fig, output_dir, "q8_mgas_overview.png", dpi)


def q9_variance_cv(all_data: dict, theme: Theme,
                   output_dir: Path, dpi: int) -> None:
    """CV% of total_ms per config for each ERC20 benchmark."""
    benchmarks = ERC20_BENCHMARKS
    active = []
    for bench in benchmarks:
        by_gd = filter_benchmark(all_data, bench, GD_ORDER)
        if by_gd:
            active.append(bench)
    if not active:
        print("  SKIP q9_variance_cv: no data")
        return

    fig, ax = plt.subplots(figsize=FIGSIZE)
    n_bench = len(active)
    n_gd = len(GD_ORDER)
    total_width = 0.75
    bar_width = total_width / n_gd

    for gd_idx, gd in enumerate(GD_ORDER):
        vals = []
        has_any = False
        for bench in active:
            by_gd = filter_benchmark(all_data, bench, [gd])
            if gd in by_gd:
                vals.append(cv_percent(col_values(by_gd[gd], "total_ms")))
                has_any = True
            else:
                vals.append(None)
        if not has_any:
            continue
        offset = (gd_idx - n_gd / 2 + 0.5) * bar_width
        x_pos = [i + offset for i in range(n_bench)]
        bar_vals = [v if v is not None else 0 for v in vals]
        bars = ax.bar(x_pos, bar_vals, bar_width, label=gd_label(gd),
                      color=COLORS[gd], alpha=0.8, edgecolor=theme.axes, linewidth=0.3)
        for i, v in enumerate(vals):
            if v is None:
                bars[i].set_visible(False)

    ax.set_xticks(range(n_bench))
    ax.set_xticklabels([b.replace("_", "\n") for b in active], fontsize=9)
    ax.set_title("Coefficient of Variation (%) — total_ms by Group Depth",
                 fontsize=13, fontweight="bold")
    ax.set_ylabel("CV (%)")
    ax.grid(axis="y", alpha=0.3)
    ax.legend(fontsize=7, ncol=4, loc="upper right")
    fig.tight_layout()
    save_fig(fig, output_dir, "q9_variance_cv.png", dpi)


# ---------------------------------------------------------------------------
# Registry & Main
# ---------------------------------------------------------------------------

ALL_GENERATORS = [
    q1_read_latency_boxplot,
    q1_read_timeseries,
    q2_write_cost_boxplot,
    q2_write_scaling_scatter,
    q3_erc20_time_breakdown_stacked,
    q3_erc20_hash_vs_commit_ratio,
    q4_erc20_read_boxplot,
    q5_erc20_write_boxplot,
    q6_mixed_boxplot,
    q6_mixed_mgas,
    q7_account_cache_hit_rates,
    q7_storage_cache_hit_rates,
    q8_mgas_overview,
    q9_variance_cv,
]


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate benchmark graphs for binary trie group-depth comparison")
    parser.add_argument("--theme", choices=["dark", "light"], default="dark",
                        help="Color theme (default: dark)")
    parser.add_argument("--output-dir", default="graphs",
                        help="Directory for output PNGs (default: graphs)")
    parser.add_argument("--data-dir", default="data",
                        help="Directory containing CSV data files (default: data)")
    parser.add_argument("--dpi", type=int, default=150,
                        help="DPI for output PNGs (default: 150)")
    args = parser.parse_args()

    theme = THEMES[args.theme]
    theme.apply()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    data_dir = Path(args.data_dir)

    print(f"Loading data from {data_dir} ...")
    all_data = load_data(data_dir)

    total_rows = sum(len(v) for v in all_data.values())
    print(f"  Total: {total_rows} rows across {len(all_data)} configs "
          f"(after filtering gas_used > 500k, run > 1)")

    if not all_data:
        print("ERROR: No data loaded. Check --data-dir path.", file=sys.stderr)
        sys.exit(1)

    # Summary of benchmarks per GD
    for gd in GD_ORDER:
        if gd not in all_data:
            continue
        benchmarks = sorted({r["benchmark"] for r in all_data[gd]})
        counts = {b: sum(1 for r in all_data[gd] if r["benchmark"] == b)
                  for b in benchmarks}
        parts = [f"{b}={counts[b]}" for b in benchmarks]
        print(f"  GD-{gd}: {', '.join(parts)}")

    print(f"\nGenerating {len(ALL_GENERATORS)} graphs (theme={args.theme}, "
          f"dpi={args.dpi}) ...")
    generated: list[str] = []
    for gen_func in ALL_GENERATORS:
        name = gen_func.__name__
        print(f"  [{name}]")
        try:
            gen_func(all_data, theme, output_dir, args.dpi)
            generated.append(name)
        except Exception as exc:
            print(f"  ERROR in {name}: {exc}", file=sys.stderr)
            import traceback
            traceback.print_exc()

    print(f"\nDone. Generated {len(generated)}/{len(ALL_GENERATORS)} graphs "
          f"in {output_dir}/")


if __name__ == "__main__":
    main()
