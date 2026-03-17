# kallisto GPU vs CPU: Cost-Normalized Benchmark Guide

This guide walks you through running a fair, cost-normalized benchmark of
GPU-kallisto vs CPU kallisto across multiple EC2 instance types, reproducing
and extending the results in Melsted et al. (2026).

---

## The Fairness Problem

The paper compares an **NVIDIA RTX 5090** (~$2,000 GPU) against a **12-core
AMD Ryzen 9900X** CPU. That is not apples-to-apples. The right comparison is:
for every dollar spent on compute, how many reads can you process per second?

This benchmark runs both tools across a range of CPU and GPU EC2 instances,
records wall-clock time, and divides throughput by the on-demand hourly rate
to get **reads per dollar** as the primary metric.

---

## Instance Matrix

| Instance | vCPU | RAM | GPU (VRAM) | NVMe | On-Demand (us-east-1) | Role |
|---|---|---|---|---|---|---|
| c7i.2xlarge | 8 | 16 GiB | — | — | $0.357/hr | CPU |
| c7i.4xlarge | 16 | 32 GiB | — | — | $0.714/hr | CPU |
| c7i.8xlarge | 32 | 64 GiB | — | — | $1.428/hr | CPU |
| c7i.16xlarge | 64 | 128 GiB | — | — | $2.856/hr | CPU |
| c8g.2xlarge | 8 | 16 GiB | — | — | $0.319/hr | CPU (Graviton4 ARM) |
| c8i.2xlarge | 8 | 16 GiB | — | — | $0.375/hr | CPU (Intel Granite Rapids) |
| c8a.2xlarge | 8 | 16 GiB | — | — | $0.431/hr | CPU (AMD EPYC) |
| g5.xlarge | 4 | 16 GiB | A10G (24 GB) | 250 GB | $1.006/hr | GPU |
| g6e.xlarge | 4 | 32 GiB | L40S (48 GB) | 250 GB | $1.860/hr | GPU |
| g6e.2xlarge | 8 | 64 GiB | L40S (48 GB) | 450 GB | $2.744/hr | GPU |

> GPU-kallisto requires Volta (sm_70) or later and at least 24 GB of VRAM for
> the human transcriptome index. The g4dn (T4, 16 GB) was tested but OOMs
> during GPU EC map construction. The g5 uses Ampere (sm_86), the g6e uses
> Ada Lovelace (sm_89).
>
> GPU instances include local NVMe SSDs (much faster than the default EBS gp3
> storage). The benchmark uses NVMe as the working directory for GPU runs.

---

## Prerequisites

- An AWS account (free tier is fine for setup; instances are not free-tier)
- A Unix/macOS terminal or WSL2 on Windows
- `jq` installed locally (used by all shell scripts)
- Python environment managed via `uv` (`uv sync` to install dependencies)
- ~$15–30 budget (total runtime across all instances is ~4–8 hours)

---

## Part 1: Minimal AWS CLI Setup

### 1.1 Install AWS CLI v2

```bash
# macOS (Homebrew)
brew install awscli

# Linux / WSL2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Verify
aws --version   # should print aws-cli/2.x.x
```

### 1.2 Create an IAM User with Minimal Permissions

This avoids using your root account credentials for CLI operations.

1. Log into the [AWS Console](https://console.aws.amazon.com)
2. Go to **IAM → Users → Create user**
3. Name it `benchmark-user`
4. Select **Attach policies directly**
5. Attach these managed policies:
   - `AmazonEC2FullAccess`
   - `AmazonS3FullAccess` (needed for the S3 data cache)
   - `ServiceQuotasFullAccess` (needed to check/request GPU quotas)
6. Add an inline policy for IAM instance profile management (needed by
   `00_setup_s3_cache.sh` to let EC2 instances access S3):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "iam:CreateRole", "iam:GetRole", "iam:PutRolePolicy",
           "iam:CreateInstanceProfile", "iam:GetInstanceProfile",
           "iam:AddRoleToInstanceProfile", "iam:PassRole"
         ],
         "Resource": [
           "arn:aws:iam::*:role/kallisto-bench-s3",
           "arn:aws:iam::*:instance-profile/kallisto-bench-s3"
         ]
       },
       {
         "Effect": "Allow",
         "Action": [
           "ec2:DescribeIamInstanceProfileAssociations",
           "ec2:AssociateIamInstanceProfile"
         ],
         "Resource": "*"
       }
     ]
   }
   ```
7. After creation, click the user → **Security credentials** → **Create
   access key** → choose "CLI" → download the CSV

### 1.3 Configure the CLI

```bash
aws configure
# AWS Access Key ID:     <paste from CSV>
# AWS Secret Access Key: <paste from CSV>
# Default region name:   us-east-1
# Default output format: json
```

Verify it works:
```bash
aws sts get-caller-identity
```

### 1.4 Create a Key Pair for SSH

```bash
aws ec2 create-key-pair \
    --key-name kallisto-bench \
    --query 'KeyMaterial' \
    --output text > ~/.ssh/kallisto-bench.pem

chmod 600 ~/.ssh/kallisto-bench.pem
```

### 1.5 Create a Security Group

```bash
# Get your default VPC id
VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query 'Vpcs[0].VpcId' --output text)

# Create the security group
SG_ID=$(aws ec2 create-security-group \
    --group-name kallisto-bench-sg \
    --description "kallisto benchmark SSH access" \
    --vpc-id $VPC_ID \
    --query 'GroupId' --output text)

# Allow SSH from your current IP only
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp --port 22 \
    --cidr ${MY_IP}/32

echo "Security group: $SG_ID"
# Save this value — you'll need it in the next step
```

### 1.6 Request GPU Quota (if needed)

New AWS accounts have a vCPU quota of 0 for GPU instances by default. All GPU
instances in this benchmark (g4dn, g5, g6e) fall under the **G and VT** quota.

```bash
# Check your current limit for G and VT instances
aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-DB2E81BA   # Running On-Demand G and VT instances

# If the value is 0, request an increase.
# GPU instances run sequentially, so 8 vCPUs is enough (the largest single
# GPU instance is g4dn.2xlarge at 8 vCPUs). Requesting 8 is usually
# auto-approved within minutes.
aws service-quotas request-service-quota-increase \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --desired-value 8
```

You can also do this through the console: EC2 → Limits → search "G and VT"
→ Request increase.

---

## Part 2: Configure and Run

### 2.1 Set Up Local Config

Save your AWS resource IDs in `config.local.sh` (gitignored):

```bash
cat > config.local.sh <<EOF
SG_ID="$SG_ID"         # from Part 1.5
SUBNET_ID="$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values=$VPC_ID \
    --query 'Subnets[0].SubnetId' --output text)"
S3_CACHE_BUCKET=""      # filled in by 00_setup_s3_cache.sh
EOF
```

### 2.2 Set Up S3 Data Cache (recommended)

This creates an S3 bucket and IAM instance profile so EC2 instances can
cache FASTQ files and the kallisto index. Without this, each instance
downloads ~45 GB from ENA (European Nucleotide Archive), which takes hours.
With the cache, subsequent instances pull from same-region S3 in minutes.

```bash
bash 00_setup_s3_cache.sh
```

### 2.3 Run the Benchmark

```bash
bash 01_launch_instances.sh
```

The script runs in two phases:
1. **Phase 1 (CPU):** Launches all 4 CPU instances concurrently, runs
   benchmarks in parallel, collects results, then terminates all.
2. **Phase 2 (GPU):** Launches GPU instances one at a time (to stay within
   the 8 vCPU G/VT quota), benchmarks each, terminates before launching the
   next.

For each instance, the script:
1. Launches the instance and writes its ID to `results/instance_ids.json`
2. SSHes in, installs dependencies, downloads test data (from S3 cache or
   ENA), and runs the benchmark
3. Polls until complete and pulls `results/timing_<name>.json`
4. Terminates the instance

Total runtime is ~4–8 hours. If the script is interrupted, re-running it
skips any instance whose `timing_<name>.json` already exists.

---

## Part 3: Analyze Results

```bash
uv run python3 04_analyze.py
```

Output files in `results/`:
- `cost_normalized_throughput_<dataset>.png` — reads/dollar across all instances
- `wall_time_<dataset>.png` — raw wall time (reproduces Fig. 1 of the paper)
- `speedup_vs_cost_<dataset>.png` — GPU speedup relative to instance price
- `summary_table.csv` — all metrics in tabular form

---

## Part 4: Teardown

Instances are terminated automatically after each benchmark. Run teardown only
if `01_launch_instances.sh` was interrupted mid-run:

```bash
bash 05_teardown.sh
# Or manually:
aws ec2 terminate-instances \
    --instance-ids $(jq -r '.[].id' results/instance_ids.json | tr '\n' ' ')
```

---

## Expected Costs

| Phase | Estimated Cost |
|---|---|
| CPU instances (4 types, concurrent, ~1.5 hr) | ~$8 |
| GPU instances (5 types, sequential, ~0.5 hr each) | ~$6 |
| S3 cache storage (~50 GB for a few days) | ~$0.10 |
| **Total** | **~$14** |

Using spot instances (see `01_launch_instances.sh` comments) cuts this to
~$4–6 but adds the risk of interruption mid-run (already-collected results
are preserved and the script will resume from where it left off).

---

## Notes on Interpretation

- The paper's RTX 5090 is not available on EC2. The closest single-GPU option
  is the L40S on `g6e.xlarge` (~$1.86/hr), which has roughly half the memory
  bandwidth but comparable FP32 compute. The g5 (A10G) and g6e (L40S) provide
  a budget-to-near-flagship range.
- **Input compression format (gzip vs bgzip) is critical for GPU performance.**
  gpu-kallisto uses nvcomp's batched deflate API for GPU-accelerated
  decompression. Standard gzip files (as distributed by ENA/SRA) are a single
  monolithic deflate stream that cannot be parallelized — the GPU decompresses
  sequentially, wasting its thousands of cores. bgzip (block-gzip, from
  htslib) compresses data as independent 64KB blocks that the GPU can
  decompress in parallel. The paper specifies bgzip-converted input. Without
  bgzip, decompression accounts for ~95% of gpu-kallisto wall time on EC2.
  Convert with: `gunzip -c file.fastq.gz | bgzip -@ 8 > file.bgz.fastq.gz`.
  CPU kallisto is unaffected (zlib handles both formats identically).
- **GPU memory requirements:** gpu-kallisto has two memory bottlenecks:
  1. **VRAM for the GPU EC map:** ~4 GB for the human transcriptome index
     (785K equivalence classes, 116M k-mers). The T4 (16 GB) OOMs during
     this phase; the A10G (24 GB) and L40S (48 GB) handle it fine.
  2. **Pinned host (system) RAM for FASTQ loading:** gpu-kallisto loads
     entire compressed FASTQ files into CUDA pinned memory
     (`cudaMallocHost`). For the large dataset (SRR30898520), R1+R2 total
     ~41 GB compressed, requiring ~48 GB+ of system RAM. Instances with
     32 GB RAM (g5.xlarge, g6e.xlarge) succeed on the small dataset but
     OOM on the large one. The g6e.2xlarge (64 GB RAM) is needed for the
     large dataset.
- **Storage: NVMe vs EBS.** GPU instances include local NVMe SSDs (~3-7 GB/s
  sequential read) that are much faster than the default EBS gp3 (125 MB/s
  baseline). However, CPU instances are compute-bound — EBS throughput is not
  their bottleneck. Switching CPU instances to NVMe would yield ≤16%
  improvement. For GPU instances, NVMe reduces wall time by ~11% vs EBS when
  using standard gzip (the I/O-bound regime). With bgzip input (GPU can
  decompress in parallel), the storage bottleneck is less dominant.
- CPU kallisto is run with all available vCPUs (`--threads=$(nproc)`) on each
  instance type so the CPU results are also best-case.
- GPU instances also run CPU kallisto on the small dataset for a same-machine
  speedup comparison (Fig. 3). The large dataset CPU run is skipped on GPU
  instances — it takes hours on their limited vCPUs (e.g. 4 on g4dn.xlarge)
  and the dedicated c7i instances provide the cost-normalized comparison.
- The EM algorithm runs on CPU in the paper's implementation even in GPU mode;
  Table 1 shows it dominates runtime at 3,148 ms. This means GPU throughput
  numbers improve significantly as read count grows (the EM portion stays
  roughly constant), which benefits the cost comparison for large datasets.
- **CUDA warmup:** The first gpu-kallisto invocation on a fresh instance
  triggers CUDA JIT compilation of PTX intermediate code to native GPU
  machine code, adding minutes of one-time overhead (e.g. ~15 min on A10G
  vs ~30s for subsequent runs). The benchmark runs an untimed warmup
  invocation before the 3 timed runs to ensure the JIT cache
  (`~/.nv/ComputeCache`) is populated and timings reflect steady-state
  performance. This mirrors how the tool would perform in production after
  the first use.

---

## Reproducibility Notes

- **Test data:** The paper uses SRR1069546 (~25M reads) as the small dataset,
  but it requires dbGaP access (study phs000424). This benchmark substitutes
  ERR188021 (~32M reads), a comparable Geuvadis sample available directly from
  ENA without access restrictions. The large dataset (SRR30898520, ~295M reads)
  is the same as the paper.
- **CUDA version:** gpu-kallisto's bundled cuCollections requires CCCL >=3.0,
  which ships with CUDA 13.0. The build explicitly targets CUDA 13.0 via
  `-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc`. The AWS Deep Learning
  Base AMI ships with multiple CUDA versions (12.6, 12.8, 12.9, 13.0).
- **nvcomp:** gpu-kallisto requires the nvcomp compression library. The
  benchmark installs nvcomp 4.0.1 from NVIDIA's download server during setup.
  nvcomp 4.x changed the batched deflate decompression API, so the build
  patches `GPUReadLoader.cuh` to remove the deprecated opts parameter.
- **S3 data cache:** An optional S3 bucket (`00_setup_s3_cache.sh`) caches
  FASTQ files and the kallisto index so that subsequent instances (especially
  GPU instances in Phase 2) download in minutes instead of hours from ENA.
