# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This is a benchmarking suite that runs cost-normalized comparisons of GPU-kallisto vs CPU kallisto across multiple EC2 instance types. The primary metric is **reads processed per dollar** (not raw speed), because the paper being reproduced (Melsted et al. 2026) compares an RTX 5090 against a 12-core CPU — an unfair cost comparison.

## Workflow (5 sequential scripts)

The scripts are numbered and run in order from your local machine:

```bash
# 1. Edit SG_ID and SUBNET_ID at the top, then:
bash 01_launch_instances.sh        # launches 9 EC2 instances, writes results/instance_ids.json

# 2. Wait ~5 min for boot, then:
bash 02_setup_and_benchmark.sh     # SSHes into each instance, runs benchmarks via nohup

# 3. Poll for completion:
bash 03_collect_results.sh --watch # polls every 60s; writes results/timing_<name>.json

# 4. Analyze:
python3 04_analyze.py              # reads timing JSONs, writes PNGs + CSV to results/

# 5. IMPORTANT — stop billing:
bash 05_teardown.sh                # terminates all instances (prompts for confirmation)
```

## Prerequisites

- AWS CLI v2 configured (`aws configure`) with a key pair named `kallisto-bench` at `~/.ssh/kallisto-bench.pem`
- `jq` installed locally (used by all shell scripts to parse `results/instance_ids.json`)
- Python environment managed via `uv` — run `uv sync` to install dependencies, then `uv run python3 04_analyze.py` to execute the analysis script
- GPU quota approved for G and P instance families in us-east-1 (quota code `L-DB2E81BA`)

## Architecture

**Instance matrix:** 4 CPU instances (`c7i` family) + 5 GPU instances (`g4dn`, `g5`, `p3` families), all in us-east-1. AMIs are hardcoded: Ubuntu 22.04 for CPU, AWS Deep Learning Base AMI for GPU.

**Benchmark scripts are sent over SSH as heredocs** — `02_setup_and_benchmark.sh` contains two large embedded shell scripts (`CPU_BENCH_SCRIPT`, `GPU_BENCH_SCRIPT`) that are piped into each instance and run via `nohup`. They build kallisto from source on the instance.

**Timing output format:**
- CPU instances emit: `TIMING:<label>:<nreads>:<threads>:<ms>`
- GPU instances emit: `TIMING:<tool>:<label>:<nreads>:<ms>` (tool = `gpu` or `cpu`)

`03_collect_results.sh` greps for `TIMING:` lines in `/tmp/bench_output.log` on each instance and parses them into per-instance JSON files.

**Test data:** Two public Geuvadis SRA samples downloaded on each instance — `SRR1069546` (~25M reads, "small") and `SRR30898520` (~295M reads, "large"). Each benchmark runs 3 times; `04_analyze.py` takes the median.

**Output files** written to `results/`:
- `instance_ids.json` — created by script 01, consumed by 02, 03, 05
- `timing_<name>.json` — per-instance timing records (one file per instance)
- `summary_table.csv`, `wall_time_<dataset>.png`, `cost_normalized_throughput_<dataset>.png`, `speedup_vs_cost_<dataset>.png`

## Key Implementation Notes

- GPU instances also run CPU kallisto for a same-machine comparison (enables the speedup scatter plot in Fig. 3)
- GPU-kallisto is built from the `gpu` branch of `https://github.com/pachterlab/kallisto.git`; installed as `gpu-kallisto` to coexist with CPU `kallisto`
- GPU-kallisto requires Volta (sm_70+); all GPU instances meet this. CMake auto-detects GPU architecture via `-DUSE_GPU=ON`
- The EM algorithm runs on CPU even in GPU mode; it dominates runtime at low read counts, so GPU advantage grows with dataset size
- Spot instance support is commented out in `01_launch_instances.sh` (`--instance-market-options` line)
- EC2 on-demand prices are hardcoded in both `01_launch_instances.sh` (for tagging) and referenced in `04_analyze.py` via the `price_per_hr` field in the JSON
