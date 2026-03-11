#!/usr/bin/env python3
"""
04_analyze.py
Cost-normalized analysis of kallisto CPU vs GPU benchmarks.

Reads all timing_*.json files from results/ and produces:
  - results/summary_table.csv
  - results/wall_time_comparison.png       (reproduces paper Fig. 1 aesthetic)
  - results/cost_normalized_throughput.png (the fair comparison)
  - results/speedup_vs_cost.png            (GPU speedup as a function of price)
"""

import json
import sys
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
import numpy as np

RESULTS_DIR = Path(__file__).parent / "results"
FIGURES_DIR = RESULTS_DIR
FIGURES_DIR.mkdir(exist_ok=True)

# ---------------------------------------------------------------------------
# Load all timing records
# ---------------------------------------------------------------------------
records = []
for fpath in sorted(RESULTS_DIR.glob("timing_*.json")):
    with open(fpath) as f:
        records.extend(json.load(f))

if not records:
    print("No timing files found in results/. Run 03_collect_results.sh first.")
    sys.exit(1)

df = pd.DataFrame(records)
print(f"Loaded {len(df)} timing records from {df['instance_name'].nunique()} instances.")

# Take median over 3 runs per (instance, tool, dataset)
df_med = (
    df.groupby(["instance_name", "instance_type", "role", "tool", "dataset",
                "n_reads", "price_per_hr"])
    ["wall_time_ms"]
    .median()
    .reset_index()
)

# Derived columns
df_med["wall_time_s"]           = df_med["wall_time_ms"] / 1000
df_med["reads_per_sec"]         = df_med["n_reads"] / df_med["wall_time_s"]
# Cost for the job: (wall_time in hours) * price_per_hr
df_med["job_cost_usd"]          = (df_med["wall_time_s"] / 3600) * df_med["price_per_hr"]
df_med["reads_per_dollar"]      = df_med["n_reads"] / df_med["job_cost_usd"].replace(0, float("nan"))
df_med["reads_per_dollar_M"]    = df_med["reads_per_dollar"] / 1e6  # millions of reads / $

# Nice display name
def nice_name(row):
    role_tag = "GPU" if row["role"] == "gpu" else "CPU"
    tool_tag = f"({row['tool']})" if row["role"] == "gpu" else ""
    return f"{row['instance_type']} {role_tag} {tool_tag}".strip()

df_med["display_name"] = df_med.apply(nice_name, axis=1)

# ---------------------------------------------------------------------------
# Save summary CSV
# ---------------------------------------------------------------------------
cols = ["instance_type", "role", "tool", "dataset", "n_reads",
        "wall_time_s", "reads_per_sec", "price_per_hr",
        "job_cost_usd", "reads_per_dollar_M"]
df_med[cols].sort_values(["dataset", "role", "instance_type"]).to_csv(
    RESULTS_DIR / "summary_table.csv", index=False, float_format="%.4f"
)
print("Saved: results/summary_table.csv")

# ---------------------------------------------------------------------------
# Color palette
# ---------------------------------------------------------------------------
CPU_COLOR = "#2176AE"   # blue
GPU_COLORS = {
    "g4dn.xlarge":  "#E36414",
    "g4dn.2xlarge": "#E36414",
    "g5.xlarge":    "#FB8B24",
    "g5.2xlarge":   "#FB8B24",
    "p3.2xlarge":   "#9A031E",
}

def get_color(row):
    if row["role"] == "cpu":
        return CPU_COLOR
    return GPU_COLORS.get(row["instance_type"], "#888888")

df_med["color"] = df_med.apply(get_color, axis=1)

# ---------------------------------------------------------------------------
# Figure 1: Wall time vs reads (matches paper Fig. 1 aesthetic)
# ---------------------------------------------------------------------------
for dataset in df_med["dataset"].unique():
    sub = df_med[df_med["dataset"] == dataset].copy()
    # Show only the primary tool per instance (gpu-kallisto for GPU, kallisto for CPU)
    sub = sub[~((sub["role"] == "gpu") & (sub["tool"] == "cpu"))]
    sub = sub.sort_values("n_reads")

    fig, ax = plt.subplots(figsize=(8, 5))

    for _, row in sub.iterrows():
        label = f"{row['instance_type']} ({'GPU-kallisto' if row['role']=='gpu' else 'kallisto'})"
        ax.scatter(row["n_reads"] / 1e6, row["wall_time_s"],
                   color=row["color"], s=80, zorder=3, label=label)

    ax.set_xlabel("Number of reads (millions)", fontsize=12)
    ax.set_ylabel("Wall time (seconds)", fontsize=12)
    ax.set_title(f"Wall time vs reads — {dataset} dataset", fontsize=13)
    ax.legend(loc="upper left", fontsize=8, framealpha=0.9)
    ax.grid(True, alpha=0.3)
    ax.set_xlim(left=0)
    ax.set_ylim(bottom=0)

    fname = FIGURES_DIR / f"wall_time_{dataset}.png"
    fig.tight_layout()
    fig.savefig(fname, dpi=150)
    plt.close()
    print(f"Saved: results/wall_time_{dataset}.png")

# ---------------------------------------------------------------------------
# Figure 2: Cost-normalized throughput (the fair comparison)
# ---------------------------------------------------------------------------
for dataset in df_med["dataset"].unique():
    sub = df_med[df_med["dataset"] == dataset].copy()
    sub = sub[~((sub["role"] == "gpu") & (sub["tool"] == "cpu"))]
    sub = sub.sort_values("reads_per_dollar_M", ascending=True)

    fig, ax = plt.subplots(figsize=(10, 5))

    bars = ax.barh(
        sub["display_name"],
        sub["reads_per_dollar_M"],
        color=sub["color"],
        edgecolor="white",
        linewidth=0.5,
    )

    # Label each bar with the value
    for bar, (_, row) in zip(bars, sub.iterrows()):
        ax.text(
            bar.get_width() + sub["reads_per_dollar_M"].max() * 0.01,
            bar.get_y() + bar.get_height() / 2,
            f"{row['reads_per_dollar_M']:.1f}M",
            va="center", fontsize=8,
        )

    # Legend patches
    from matplotlib.patches import Patch
    legend_handles = [
        Patch(color=CPU_COLOR, label="CPU kallisto"),
        Patch(color="#E36414", label="GPU-kallisto (T4)"),
        Patch(color="#FB8B24", label="GPU-kallisto (A10G)"),
        Patch(color="#9A031E", label="GPU-kallisto (V100)"),
    ]
    ax.legend(handles=legend_handles, fontsize=9, loc="lower right")

    ax.set_xlabel("Reads processed per dollar (millions)", fontsize=12)
    ax.set_title(
        f"Cost-normalized throughput — {dataset} dataset\n"
        f"Higher is better. Accounts for on-demand EC2 price.",
        fontsize=12,
    )
    ax.grid(True, axis="x", alpha=0.3)
    ax.set_xlim(right=sub["reads_per_dollar_M"].max() * 1.18)

    fig.tight_layout()
    fname = FIGURES_DIR / f"cost_normalized_throughput_{dataset}.png"
    fig.savefig(fname, dpi=150)
    plt.close()
    print(f"Saved: results/cost_normalized_throughput_{dataset}.png")

# ---------------------------------------------------------------------------
# Figure 3: GPU speedup vs GPU hourly cost
# ---------------------------------------------------------------------------
# For GPU instances that also ran CPU-kallisto, compute speedup
gpu_rows = df_med[(df_med["role"] == "gpu") & (df_med["tool"] == "gpu")]
cpu_rows = df_med[(df_med["role"] == "gpu") & (df_med["tool"] == "cpu")]

if not cpu_rows.empty:
    merged = gpu_rows.merge(
        cpu_rows[["instance_name", "dataset", "wall_time_s"]],
        on=["instance_name", "dataset"],
        suffixes=("_gpu", "_cpu"),
    )
    merged["speedup"] = merged["wall_time_s_cpu"] / merged["wall_time_s_gpu"]

    for dataset in merged["dataset"].unique():
        sub = merged[merged["dataset"] == dataset].sort_values("price_per_hr")

        fig, ax = plt.subplots(figsize=(7, 5))
        for _, row in sub.iterrows():
            color = GPU_COLORS.get(row["instance_type"], "#888888")
            ax.scatter(row["price_per_hr"], row["speedup"],
                       color=color, s=120, zorder=3)
            ax.annotate(
                row["instance_type"],
                (row["price_per_hr"], row["speedup"]),
                textcoords="offset points", xytext=(6, 4), fontsize=8,
            )

        ax.axhline(1, color="gray", linestyle="--", linewidth=0.8, label="No speedup")
        ax.set_xlabel("Instance hourly price (USD)", fontsize=12)
        ax.set_ylabel("GPU-kallisto speedup over CPU kallisto\n(same instance)", fontsize=11)
        ax.set_title(
            f"GPU speedup vs cost — {dataset} dataset\n"
            f"Both tools run on the same instance.",
            fontsize=12,
        )
        ax.grid(True, alpha=0.3)
        ax.legend(fontsize=9)

        fig.tight_layout()
        fname = FIGURES_DIR / f"speedup_vs_cost_{dataset}.png"
        fig.savefig(fname, dpi=150)
        plt.close()
        print(f"Saved: results/speedup_vs_cost_{dataset}.png")
else:
    print("No same-instance CPU/GPU comparisons found; skipping speedup plot.")

# ---------------------------------------------------------------------------
# Print summary table
# ---------------------------------------------------------------------------
print("\n" + "=" * 70)
print("SUMMARY: Cost-normalized throughput (millions of reads per $1 spent)")
print("=" * 70)
for dataset in sorted(df_med["dataset"].unique()):
    print(f"\n  Dataset: {dataset}")
    sub = df_med[df_med["dataset"] == dataset]
    sub = sub[~((sub["role"] == "gpu") & (sub["tool"] == "cpu"))]
    sub = sub.sort_values("reads_per_dollar_M", ascending=False)
    for _, row in sub.iterrows():
        bar = "█" * int(row["reads_per_dollar_M"] / sub["reads_per_dollar_M"].max() * 30)
        print(f"  {row['display_name']:35s}  {row['reads_per_dollar_M']:6.1f}M/$ {bar}")

print("\nDone. Check results/ for all output files.")
