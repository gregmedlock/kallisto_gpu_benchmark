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

**Instance matrix:** CPU instances (`c7i`, `c8g`, `c8i`, `c8a` families) + GPU instances (`g5`, `g6e` families), all in us-east-1. AMIs are hardcoded: Ubuntu 22.04 for CPU (x86_64 and arm64 variants), AWS Deep Learning Base AMI for GPU. g4dn (T4, 16 GB VRAM) was excluded — gpu-kallisto OOMs building the GPU EC map. gpu-kallisto also loads entire compressed FASTQs into CUDA pinned host memory (`cudaMallocHost`), so the large dataset (~41 GB compressed) requires >=48 GB system RAM (only g6e.2xlarge with 64 GB succeeds).

**Benchmark scripts are sent over SSH as heredocs** — `02_setup_and_benchmark.sh` contains two large embedded shell scripts (`CPU_BENCH_SCRIPT`, `GPU_BENCH_SCRIPT`) that are piped into each instance and run via `nohup`. They build kallisto from source on the instance.

**Timing output format:**
- CPU instances emit: `TIMING:<label>:<nreads>:<threads>:<ms>`
- GPU instances emit: `TIMING:<tool>:<label>:<nreads>:<ms>` (tool = `gpu` or `cpu`)

`03_collect_results.sh` greps for `TIMING:` lines in `~/bench_output.log` on each instance and parses them into per-instance JSON files.

**Test data:** Two public Geuvadis RNA-seq samples downloaded on each instance — `ERR188021` (~32M reads, "small") and `SRR30898520` (~295M reads, "large"). The paper used `SRR1069546` for small, but it requires dbGaP access (phs000424); `ERR188021` is a comparable Geuvadis sample available directly from ENA. Each benchmark runs 3 times; `04_analyze.py` takes the median.

**Output files** written to `results/`:
- `instance_ids.json` — created by script 01, consumed by 02, 03, 05
- `timing_<name>.json` — per-instance timing records (one file per instance)
- `summary_table.csv`, `wall_time_<dataset>.png`, `cost_normalized_throughput_<dataset>.png`, `speedup_vs_cost_<dataset>.png`

## Key Implementation Notes

- GPU instances also run CPU kallisto on the small dataset for a same-machine speedup comparison (Fig. 3). The large dataset CPU run is skipped on GPU instances — it takes hours on limited vCPUs and the c7i CPU data provides the cost-normalized comparison
- GPU-kallisto is built from the `gpu` branch of `https://github.com/pachterlab/kallisto.git`; installed as `gpu-kallisto` to coexist with CPU `kallisto`
- GPU-kallisto requires Volta (sm_70+); all GPU instances meet this. CMake auto-detects GPU architecture via `-DCMAKE_CUDA_ARCHITECTURES=native`
- **CUDA version constraint:** gpu-kallisto's bundled cuCollections requires CCCL >=3.0, which ships with CUDA 13.0. The build explicitly uses CUDA 13.0 (`-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc`). The Deep Learning Base AMI ships with multiple CUDA versions (12.6, 12.8, 12.9, 13.0).
- **nvcomp dependency:** gpu-kallisto requires the nvcomp library. Version 4.0.1 is installed from NVIDIA's download server during the GPU benchmark setup. nvcomp 4.x changed the batched deflate decompression API (removed opts parameter), so `GPUReadLoader.cuh` is patched at build time.
- The EM algorithm runs on CPU even in GPU mode; it dominates runtime at low read counts, so GPU advantage grows with dataset size
- Spot instance support is commented out in `01_launch_instances.sh` (`--instance-market-options` line)
- EC2 on-demand prices are hardcoded in both `01_launch_instances.sh` (for tagging) and referenced in `04_analyze.py` via the `price_per_hr` field in the JSON

## Input Compression Format: gzip vs bgzip

**This is the single most important variable for GPU-kallisto performance.**

gpu-kallisto uses nvcomp's **batched deflate** API for GPU-accelerated decompression. The key distinction:

- **Standard gzip** (`.fastq.gz` from ENA/SRA): the entire file is a single monolithic deflate stream. The GPU cannot parallelize decompression — it processes the stream essentially sequentially regardless of CUDA core count. This makes decompression the dominant bottleneck (~95% of wall time).
- **bgzip** (block-gzip, from htslib): the file is compressed as thousands of independent 64KB deflate blocks. The GPU can decompress all blocks in parallel, fully utilizing its memory bandwidth and compute. Files are gzip-compatible (any tool reads them), but the internal structure enables massive parallelism.

The paper (Melsted et al. 2026) specifies that input files were **converted to bgzip format** before benchmarking. Without this conversion, gpu-kallisto on an L40S takes ~650s for the large dataset; with bgzip the same data may complete in ~50s (matching the paper's RTX 5090 result, accounting for hardware differences).

**Conversion:** `gunzip -c file.fastq.gz | bgzip -@ 8 > file.bgz.fastq.gz` (requires `tabix` or `htslib` package). The `bgzip` output is the same size as gzip and readable by all standard tools.

CPU kallisto is unaffected by this distinction — it decompresses on CPU using zlib, which processes gzip and bgzip identically (single-threaded stream decompression).

## Benchmarking Best Practices for AWS EC2

### Auto-shutdown to prevent cost overruns

Always configure instances to shut down automatically when benchmarks complete. The pattern:

```bash
# Write a shutdown watcher script
cat > ~/auto_shutdown.sh << 'EOF'
#!/bin/bash
while ! grep -q "benchmark complete" ~/bench_output.log 2>/dev/null; do
    sleep 60
done
sleep 30
sudo shutdown -h now
EOF

# Launch benchmark and watcher together
nohup bash ~/benchmark.sh > ~/bench_output.log 2>&1 &
nohup bash ~/auto_shutdown.sh > ~/auto_shutdown.log 2>&1 &
```

The benchmark script must print a known sentinel string (e.g., "benchmark complete") as its final output. The watcher polls the log and triggers `shutdown -h` (stop, not terminate) so the EBS volume and logs are preserved for collection. After collecting results, **terminate** the instance to stop all charges.

**Important:** `shutdown -h` stops the instance but EBS storage charges continue (~$0.08/GB/month). Always terminate instances after collecting results.

### Persisting logs across instance stop/start cycles

- **Always log to `~/` (home directory on EBS), never `/tmp`.** The `/tmp` filesystem is cleared on instance stop/start, so benchmark results will be lost if the instance is stopped before collection.
- **NVMe instance store (`/opt/dlami/nvme` on Deep Learning AMIs) is ephemeral.** Data on instance store volumes is lost on stop/start/terminate. Use NVMe for benchmark working data (fast I/O) but copy results to EBS or the log before shutdown.

### Evaluating bottlenecks before scaling up

Before benchmarking on expensive instances, identify whether the workload is **compute-bound**, **I/O-bound**, or **memory-bound**:

- **Compute-bound** (CPU kallisto): wall time scales inversely with vCPU count. Scaling to larger instances with more cores improves performance proportionally. Cost-efficiency is roughly flat across instance sizes within the same family.
- **I/O-bound** (gpu-kallisto with standard gzip on EBS): GPU compute finishes in seconds but waits hundreds of seconds for data. Upgrading to a faster GPU wastes money. Instead: switch to NVMe instance store, use bgzip format, or increase EBS throughput (gp3 supports up to 1000 MB/s for extra cost).
- **Memory-bound** (gpu-kallisto `cudaMallocHost`): if the dataset exceeds system RAM minus the pinned allocation, the OS page cache cannot hold input files and every timed run re-reads from disk. Doubling RAM (e.g., g6e.2xlarge 64GB → g6e.4xlarge 128GB) gives a modest ~11% improvement — helpful but not transformative, because the bottleneck is decompression throughput, not raw I/O.

**Quick diagnostic:** If GPU-kallisto's pipeline summary shows "I/O & Decompression" at >80% of wall time, the problem is decompression format (gzip vs bgzip), not hardware.

### Memory requirements for gpu-kallisto

gpu-kallisto has two memory bottlenecks:

1. **VRAM for the GPU EC map:** ~4 GB for the human transcriptome index (785K equivalence classes, 116M k-mers). The T4 (16 GB VRAM) OOMs during this phase; A10G (24 GB) and L40S (48 GB) succeed.
2. **Pinned host RAM for FASTQ loading:** `cudaMallocHost` allocates pinned (page-locked) system RAM equal to the total compressed FASTQ size. For the large dataset, R1+R2 ≈ 41 GB compressed, requiring ≥48 GB system RAM. Instances with 32 GB (g5.xlarge, g6e.xlarge) succeed on the small dataset but OOM on the large one.

**Rule of thumb:** system RAM must be ≥ 1.2× the total compressed input size, plus ~8 GB for the OS, CUDA context, and kallisto index.

### GPU vCPU quota management

All G-family instances (g4dn, g5, g6e, g7e) share the "Running On-Demand G and VT instances" quota (`L-DB2E81BA`). The quota is measured in vCPUs, not instances. Common sizes:
- 8 vCPUs: can run one g6e.2xlarge at a time (sufficient for sequential benchmarking)
- 16 vCPUs: can run one g6e.4xlarge, or two g6e.2xlarge concurrently

Quota increases from 8→16 are typically auto-approved in minutes. Larger increases may require a support case. Check status: `aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA`

### NVMe instance store usage

Many GPU instances (g5, g6e) include local NVMe SSDs that are much faster than EBS gp3 (~3-7 GB/s sequential vs 125 MB/s default). On the Deep Learning Base AMI, NVMe is pre-mounted at `/opt/dlami/nvme`. Use it as the benchmark working directory:

```bash
NVME_DIR="/opt/dlami/nvme/kallisto_bench"
sudo mkdir -p "$NVME_DIR" && sudo chown ubuntu:ubuntu "$NVME_DIR"
```

NVMe data is ephemeral — lost on instance stop/start. Download data to NVMe at the start of each run.

### Disabling unattended-upgrades

The `unattended-upgrades` service on Ubuntu can trigger unexpected shutdowns or reboots during benchmarks. Disable it in the instance user-data:

```bash
sudo systemctl disable --now unattended-upgrades
```
