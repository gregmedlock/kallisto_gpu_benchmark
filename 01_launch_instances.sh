#!/usr/bin/env bash
# =============================================================================
# 01_launch_instances.sh
# Launch EC2 instances for the kallisto benchmark.
# CPU instances (c7i family) run concurrently (~120 vCPUs needed).
# GPU instances (g4dn, g5) run sequentially to stay within the 8 vCPU G/VT quota.
#
# Set your values in config.local.sh (gitignored), or export them before running.
SG_ID="${SG_ID:-sg-XXXXXXXXXXXXXXXX}"      # from Part 1.5 of the README
SUBNET_ID="${SUBNET_ID:-subnet-XXXXXXXX}"  # from Part 2 of the README
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
    # shellcheck source=config.local.sh
    source "$SCRIPT_DIR/config.local.sh"
fi
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

KEY_NAME="kallisto-bench"
KEY="$HOME/.ssh/kallisto-bench.pem"

# Ubuntu 22.04 LTS (HVM, SSD) in us-east-1.
# GPU instances need a CUDA-capable AMI; we use the AWS Deep Learning Base AMI
# which ships with CUDA 12, NVIDIA drivers, and conda pre-installed.
CPU_AMI="ami-0c7217cdde317cfec"          # Ubuntu 22.04 LTS us-east-1
GPU_AMI="ami-02d9d948a3b2142ba"          # Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20260307 us-east-1

# ---------------------------------------------------------------------------
# Instance definitions: name:instance_type:ami:role:price_per_hr
# Plain indexed array — compatible with bash 3.2 (macOS default).
# ---------------------------------------------------------------------------
INSTANCES=(
    "cpu-c7i-2xl:c7i.2xlarge:$CPU_AMI:cpu:0.357"
    "cpu-c7i-4xl:c7i.4xlarge:$CPU_AMI:cpu:0.714"
    "cpu-c7i-8xl:c7i.8xlarge:$CPU_AMI:cpu:1.428"
    "cpu-c7i-16xl:c7i.16xlarge:$CPU_AMI:cpu:2.856"
    "gpu-g4dn-xl:g4dn.xlarge:$GPU_AMI:gpu:0.526"
    "gpu-g4dn-2xl:g4dn.2xlarge:$GPU_AMI:gpu:0.752"
    "gpu-g5-xl:g5.xlarge:$GPU_AMI:gpu:1.006"
    "gpu-g5-2xl:g5.2xlarge:$GPU_AMI:gpu:1.212"
    # "gpu-p3-2xl:p3.2xlarge:$GPU_AMI:gpu:3.060"  # requires P-instance quota (0 by default)
)

# ---------------------------------------------------------------------------
# User-data: runs on first boot; installs minimal tools needed for SSH setup
# ---------------------------------------------------------------------------
CPU_USERDATA=$(base64 <<'USERDATA' | tr -d '\n'
#!/bin/bash
apt-get update -y
apt-get install -y build-essential cmake git curl wget zlib1g-dev libbz2-dev \
    liblzma-dev libcurl4-openssl-dev libssl-dev python3-pip unzip awscli
# Mark as ready
touch /tmp/bootstrap_done
USERDATA
)

GPU_USERDATA=$(base64 <<'USERDATA' | tr -d '\n'
#!/bin/bash
# Deep Learning AMI already has CUDA — just add build tools
apt-get update -y
apt-get install -y build-essential cmake git curl wget zlib1g-dev libbz2-dev \
    liblzma-dev libcurl4-openssl-dev libssl-dev python3-pip unzip awscli
touch /tmp/bootstrap_done
USERDATA
)

# ---------------------------------------------------------------------------
# Helper: launch one instance, returning its ID
# ---------------------------------------------------------------------------
launch_instance() {
    local NAME="$1" ITYPE="$2" AMI="$3" ROLE="$4" USERDATA_B64="$5"
    # To use Spot instead (saves ~60-70%), add this flag to the command below:
    #   --instance-market-options '{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}'
    aws ec2 run-instances \
        --image-id "$AMI" \
        --instance-type "$ITYPE" \
        --key-name "$KEY_NAME" \
        --security-group-ids "$SG_ID" \
        --subnet-id "$SUBNET_ID" \
        --associate-public-ip-address \
        --user-data "$USERDATA_B64" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=kallisto-bench-$NAME},{Key=BenchmarkRole,Value=$ROLE}]" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' \
        --query 'Instances[0].InstanceId' \
        --output text
}

OUTPUT_JSON="$RESULTS_DIR/instance_ids.json"

# Pre-count instances by role for display
CPU_TOTAL=0; GPU_TOTAL=0
for ENTRY in "${INSTANCES[@]}"; do
    IFS=: read -r _N _I _A ROLE _P <<< "$ENTRY"
    [[ "$ROLE" == "cpu" ]] && CPU_TOTAL=$(( CPU_TOTAL + 1 ))
    [[ "$ROLE" == "gpu" ]] && GPU_TOTAL=$(( GPU_TOTAL + 1 ))
done

# ---------------------------------------------------------------------------
# Phase 1: CPU instances — launch all concurrently, benchmark, terminate all
# ---------------------------------------------------------------------------
echo "=== Phase 1: CPU instances (concurrent) ==="
CPU_LAUNCHED_JSON="[]"
COUNT=0

for ENTRY in "${INSTANCES[@]}"; do
    IFS=: read -r NAME ITYPE AMI ROLE PRICE <<< "$ENTRY"
    [[ "$ROLE" != "cpu" ]] && continue
    COUNT=$(( COUNT + 1 ))

    if [ -f "$RESULTS_DIR/timing_${NAME}.json" ]; then
        echo "[cpu $COUNT/$CPU_TOTAL] $NAME: already complete, skipping."
        continue
    fi

    echo ""
    echo "[cpu $COUNT/$CPU_TOTAL] Launching $NAME ($ITYPE, \$$PRICE/hr)..."
    INSTANCE_ID=$(launch_instance "$NAME" "$ITYPE" "$AMI" "$ROLE" "$CPU_USERDATA")
    echo "  Launched: $INSTANCE_ID"

    CPU_LAUNCHED_JSON=$(echo "$CPU_LAUNCHED_JSON" | jq \
        --arg id "$INSTANCE_ID" --arg name "$NAME" --arg type "$ITYPE" \
        --arg role "$ROLE" --arg price "$PRICE" \
        '. += [{"id": $id, "name": $name, "instance_type": $type, "role": $role, "price_per_hr": $price}]')
done

if [[ "$(echo "$CPU_LAUNCHED_JSON" | jq 'length')" -gt 0 ]]; then
    echo "$CPU_LAUNCHED_JSON" > "$OUTPUT_JSON"
    echo ""
    echo "All CPU instances launched. Starting benchmarks..."
    bash "$SCRIPT_DIR/02_setup_and_benchmark.sh"
    echo ""
    echo "Waiting for CPU benchmarks to complete..."
    bash "$SCRIPT_DIR/03_collect_results.sh" --watch
    echo ""
    echo "Terminating CPU instances..."
    while IFS= read -r INST_JSON; do
        ID=$(echo "$INST_JSON" | jq -r '.id')
        NAME=$(echo "$INST_JSON" | jq -r '.name')
        echo "  Terminating $ID ($NAME)..."
        aws ec2 terminate-instances --instance-ids "$ID" \
            --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' \
            --output table
    done < <(echo "$CPU_LAUNCHED_JSON" | jq -c '.[]')
fi

# ---------------------------------------------------------------------------
# Phase 2: GPU instances — sequential (8 vCPU quota limit)
# ---------------------------------------------------------------------------
echo ""
echo "=== Phase 2: GPU instances (sequential, one at a time) ==="
COUNT=0

for ENTRY in "${INSTANCES[@]}"; do
    IFS=: read -r NAME ITYPE AMI ROLE PRICE <<< "$ENTRY"
    [[ "$ROLE" != "gpu" ]] && continue
    COUNT=$(( COUNT + 1 ))

    if [ -f "$RESULTS_DIR/timing_${NAME}.json" ]; then
        echo "[gpu $COUNT/$GPU_TOTAL] $NAME: already complete, skipping."
        continue
    fi

    echo ""
    echo "[gpu $COUNT/$GPU_TOTAL] Launching $NAME ($ITYPE, \$$PRICE/hr)..."
    INSTANCE_ID=$(launch_instance "$NAME" "$ITYPE" "$AMI" "$ROLE" "$GPU_USERDATA")
    echo "  Launched: $INSTANCE_ID"

    jq -n \
        --arg id "$INSTANCE_ID" --arg name "$NAME" --arg type "$ITYPE" \
        --arg role "$ROLE" --arg price "$PRICE" \
        '[{"id": $id, "name": $name, "instance_type": $type, "role": $role, "price_per_hr": $price}]' \
        > "$OUTPUT_JSON"

    bash "$SCRIPT_DIR/02_setup_and_benchmark.sh"
    bash "$SCRIPT_DIR/03_collect_results.sh" --watch

    echo "  Terminating $INSTANCE_ID ($NAME)..."
    aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" \
        --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' \
        --output table
    echo "  Waiting for $INSTANCE_ID to fully terminate (releases vCPU quota)..."
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

    echo "  [$NAME] done. Timing saved to $RESULTS_DIR/timing_${NAME}.json"
done

echo ""
echo "All instances complete. Run analysis:"
echo "  uv run python3 04_analyze.py"
