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

| Instance | vCPU | GPU | On-Demand (us-east-1) | Role |
|---|---|---|---|---|
| c7i.2xlarge | 8 | — | $0.357/hr | CPU |
| c7i.4xlarge | 16 | — | $0.714/hr | CPU |
| c7i.8xlarge | 32 | — | $1.428/hr | CPU |
| c7i.16xlarge | 64 | — | $2.856/hr | CPU |
| g4dn.xlarge | 4 | T4 (Turing) | $0.526/hr | GPU |
| g4dn.2xlarge | 8 | T4 (Turing) | $0.752/hr | GPU |
| g5.xlarge | 4 | A10G (Ampere) | $1.006/hr | GPU |
| g5.2xlarge | 8 | A10G (Ampere) | $1.212/hr | GPU |
| p3.2xlarge | 8 | V100 (Volta) | $3.06/hr | GPU |

> GPU-kallisto requires Volta (sm_70) or later. All GPU instances listed meet
> this requirement. The g4dn uses Turing (sm_75).

---

## Prerequisites

- An AWS account (free tier is fine for setup; instances are not free-tier)
- A Unix/macOS terminal or WSL2 on Windows
- ~$15–30 budget (total runtime across all instances is ~2–4 hours)
- The Geuvadis data is public on SRA; no data transfer fees apply for
  downloading within the same AWS region

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
5. Attach these two managed policies:
   - `AmazonEC2FullAccess`
   - `AmazonS3FullAccess` (needed to stage results)
6. After creation, click the user → **Security credentials** → **Create
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

New AWS accounts have a vCPU quota of 0 for GPU instances by default.

```bash
# Check your current limit for G and P instances - requires ServiceQuotasFullAccess policy for your user as well
aws service-quotas get-service-quota \
    --service-code ec2 \
    --quota-code L-DB2E81BA   # Running On-Demand G and VT instances

# If the value is 0, request an increase.
# The 5 GPU instances together need 32 vCPUs to run simultaneously,
# but requesting 8 is usually auto-approved within minutes and is enough
# to run instances one at a time. Request 32 only if you want all 5 at once
# (may take hours or days to approve).
aws service-quotas request-service-quota-increase \
    --service-code ec2 \
    --quota-code L-DB2E81BA \
    --desired-value 8
```

You can also do this through the console: EC2 → Limits → search "G instances"
→ Request increase.

---

## Part 2: Run the Full Benchmark

Edit `01_launch_instances.sh` to set your `SG_ID` and `SUBNET_ID`, then run
it. The script handles the entire pipeline — launch, benchmark, collect, and
terminate — **one instance at a time**, so only one instance is running at any
moment (staying within the 8 vCPU GPU quota).

```bash
# Find a subnet in your default VPC (uses VPC_ID from Part 1.5)
SUBNET_ID=$(aws ec2 describe-subnets \
    --filters Name=vpc-id,Values=$VPC_ID \
    --query 'Subnets[0].SubnetId' --output text)

# Edit SG_ID and SUBNET_ID at the top of the script, then:
bash 01_launch_instances.sh
```

For each instance, the script:
1. Launches the instance and writes its ID to `results/instance_ids.json`
2. SSHes in, installs dependencies, downloads Geuvadis samples, runs the benchmark
3. Polls until complete and pulls `results/timing_<name>.json`
4. Terminates the instance before launching the next

Total runtime is ~8–12 hours (each instance takes 60–120 minutes, dominated by
SRA downloads and compilation). If the script is interrupted, re-running it
skips any instance whose `timing_<name>.json` already exists.

---

## Part 3: Analyze Results

```bash
# Run cost-normalized analysis and generate plots
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
| CPU instances (4 types × ~1.5 hr avg) | ~$5 |
| GPU instances (5 types × ~0.5 hr avg) | ~$8 |
| Data transfer (SRA → EC2, same region) | ~$0 |
| **Total** | **~$13** |

Instances run sequentially so costs are the same as before — only one instance
is billed at a time. Using spot instances (see `01_launch_instances.sh`
comments) cuts this to ~$4–6 but adds the risk of interruption mid-run
(already-collected results are preserved and the script will resume from where
it left off).

---

## Notes on Interpretation

- The paper's RTX 5090 is not available on EC2. The closest is an H100 on
  `p5.48xlarge` (~$98/hr), which would be prohibitively expensive for this
  benchmark. The A10G (`g5`) and V100 (`p3`) bracket a reasonable price range.
- CPU kallisto is run with all available vCPUs (`--threads=$(nproc)`) on each
  instance type so the CPU results are also best-case.
- The EM algorithm runs on CPU in the paper's implementation even in GPU mode;
  Table 1 shows it dominates runtime at 3,148 ms. This means GPU throughput
  numbers improve significantly as read count grows (the EM portion stays
  roughly constant), which benefits the cost comparison for large datasets.
