#!/usr/bin/env bash
# =============================================================================
# 02_setup_and_benchmark.sh
# SSH into each instance, install kallisto / gpu-kallisto, download test data,
# and run the benchmark. Timing results are written locally.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
INSTANCE_JSON="$RESULTS_DIR/instance_ids.json"
KEY="$HOME/.ssh/kallisto-bench.pem"

# SRA accessions: one smaller (~25M reads) and one larger (~295M reads) sample
# These are publicly available Geuvadis samples used in the paper.
SMALL_SRR="SRR1069546"   # ~25M paired-end reads
LARGE_SRR="SRR30898520"  # ~295M paired-end reads (paper's large dataset)

# ---- CPU benchmark script (sent via heredoc over SSH) ---------------------
read -r -d '' CPU_BENCH_SCRIPT << 'CPUEOF' || true
#!/bin/bash
set -euo pipefail
THREADS=$(nproc)
WORKDIR="$HOME/kallisto_bench"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ---- Install kallisto from source ----------------------------------------
if ! command -v kallisto &>/dev/null; then
    log "Building kallisto from source..."
    rm -rf kallisto
    git clone --depth=1 https://github.com/pachterlab/kallisto.git
    cd kallisto && mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j"$THREADS" || make  # parallel build has flaky bifrost dependency; retry sequentially
    sudo make install
    cd "$WORKDIR"
fi
KALLISTO=$(which kallisto)
log "kallisto: $($KALLISTO version)"

# ---- Download reference index --------------------------------------------
log "Building human kallisto index (Ensembl 113)..."
if [ ! -f human_index.idx ] || [ ! -s human_index.idx ]; then
    rm -f human_index.idx.gz human_index.idx
    wget -q "https://ftp.ensembl.org/pub/release-113/fasta/homo_sapiens/cdna/Homo_sapiens.GRCh38.cdna.all.fa.gz" \
        -O human_transcriptome.fa.gz
    log "Indexing transcriptome (takes ~10-15 min)..."
    kallisto index -i human_index.idx human_transcriptome.fa.gz
    rm -f human_transcriptome.fa.gz
fi

# ---- Download test samples -----------------------------------------------
# Download paired FASTQ directly from ENA (no SRA toolkit required).
# ENA FTP path: /vol1/fastq/SRR{first3}/{subdir}/{SRR}/
# subdir depends on accession digit count: 7→00{d7}, 8→0{d7d8}, 9+→{d7d8d9}
download_sample() {
    local SRR="$1"
    if [ ! -f "${SRR}_1.fastq.gz" ] || [ ! -s "${SRR}_1.fastq.gz" ]; then
        log "Downloading $SRR from ENA..."
        local NUM="${SRR#SRR}"
        local NLEN="${#NUM}"
        local PREFIX="SRR${NUM:0:3}"
        if   [ "$NLEN" -le 6 ]; then local SUB=""
        elif [ "$NLEN" -eq 7 ]; then local SUB="/00${NUM: -1}"
        elif [ "$NLEN" -eq 8 ]; then local SUB="/0${NUM: -2}"
        else                          local SUB="/${NUM: -3}"
        fi
        local BASE="ftp://ftp.sra.ebi.ac.uk/vol1/fastq/${PREFIX}${SUB}/${SRR}"
        rm -f "${SRR}_1.fastq.gz" "${SRR}_2.fastq.gz"
        wget -q "${BASE}/${SRR}_1.fastq.gz" -O "${SRR}_1.fastq.gz"
        wget -q "${BASE}/${SRR}_2.fastq.gz" -O "${SRR}_2.fastq.gz"
    fi
}

download_sample "${SMALL_SRR}"
download_sample "${LARGE_SRR}"

# ---- Run benchmark -------------------------------------------------------
run_benchmark() {
    local SRR="$1"
    local LABEL="$2"
    local R1="${SRR}_1.fastq.gz"
    local R2="${SRR}_2.fastq.gz"
    local NREADS
    NREADS=$(zcat "$R1" | awk 'NR%4==1' | wc -l)

    log "Benchmarking $LABEL ($NREADS reads, $THREADS threads)..."
    mkdir -p "out_${LABEL}"

    # Warm up disk cache with a dry run, then time 3 real runs
    for RUN in 1 2 3; do
        START=$(date +%s%3N)
        "$KALLISTO" quant \
            -i human_index.idx \
            -o "out_${LABEL}/run_${RUN}" \
            --threads "$THREADS" \
            -l 175 -s 25 \
            "$R1" "$R2" 2>/dev/null
        END=$(date +%s%3N)
        ELAPSED=$(( END - START ))
        echo "TIMING:${LABEL}:${NREADS}:${THREADS}:${ELAPSED}"
    done
}

run_benchmark "$SMALL_SRR" "small"
run_benchmark "$LARGE_SRR" "large"

log "CPU benchmark complete."
CPUEOF

# ---- GPU benchmark script ------------------------------------------------
read -r -d '' GPU_BENCH_SCRIPT << 'GPUEOF' || true
#!/bin/bash
set -euo pipefail
THREADS=$(nproc)
WORKDIR="$HOME/kallisto_bench"
mkdir -p "$WORKDIR" && cd "$WORKDIR"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Detect CUDA compute capability
GPU_INFO=$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null | head -1)
log "GPU: $GPU_INFO"

# ---- Build GPU-kallisto from source (gpu branch) -------------------------
if ! command -v gpu-kallisto &>/dev/null; then
    log "Building GPU-kallisto..."
    rm -rf kallisto-gpu
    git clone --branch gpu --depth=1 https://github.com/pachterlab/kallisto.git kallisto-gpu
    cd kallisto-gpu && mkdir build && cd build
    # Let CMake auto-detect GPU architecture
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_GPU=ON
    make -j"$THREADS" || make  # parallel build has flaky bifrost dependency; retry sequentially
    sudo cp src/kallisto /usr/local/bin/gpu-kallisto
    cd "$WORKDIR"
fi

# Also install CPU kallisto for a same-machine comparison
if ! command -v kallisto &>/dev/null; then
    log "Building CPU kallisto..."
    git clone --depth=1 https://github.com/pachterlab/kallisto.git kallisto-cpu
    cd kallisto-cpu && mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j"$THREADS"
    sudo make install
    cd "$WORKDIR"
fi


if [ ! -f human_index.idx ] || [ ! -s human_index.idx ]; then
    rm -f human_index.idx.gz human_index.idx
    log "Downloading transcriptome FASTA..."
    wget -q "https://ftp.ensembl.org/pub/release-113/fasta/homo_sapiens/cdna/Homo_sapiens.GRCh38.cdna.all.fa.gz" \
        -O human_transcriptome.fa.gz
    log "Indexing transcriptome (takes ~10-15 min)..."
    kallisto index -i human_index.idx human_transcriptome.fa.gz
    rm -f human_transcriptome.fa.gz
fi

download_sample() {
    local SRR="$1"
    if [ ! -f "${SRR}_1.fastq.gz" ] || [ ! -s "${SRR}_1.fastq.gz" ]; then
        log "Downloading $SRR from ENA..."
        local NUM="${SRR#SRR}"
        local NLEN="${#NUM}"
        local PREFIX="SRR${NUM:0:3}"
        if   [ "$NLEN" -le 6 ]; then local SUB=""
        elif [ "$NLEN" -eq 7 ]; then local SUB="/00${NUM: -1}"
        elif [ "$NLEN" -eq 8 ]; then local SUB="/0${NUM: -2}"
        else                          local SUB="/${NUM: -3}"
        fi
        local BASE="ftp://ftp.sra.ebi.ac.uk/vol1/fastq/${PREFIX}${SUB}/${SRR}"
        rm -f "${SRR}_1.fastq.gz" "${SRR}_2.fastq.gz"
        wget -q "${BASE}/${SRR}_1.fastq.gz" -O "${SRR}_1.fastq.gz"
        wget -q "${BASE}/${SRR}_2.fastq.gz" -O "${SRR}_2.fastq.gz"
    fi
}

download_sample "${SMALL_SRR}"
download_sample "${LARGE_SRR}"

# ---- Run GPU benchmark ---------------------------------------------------
run_gpu_benchmark() {
    local SRR="$1"
    local LABEL="$2"
    local R1="${SRR}_1.fastq.gz"
    local R2="${SRR}_2.fastq.gz"
    local NREADS
    NREADS=$(zcat "$R1" | awk 'NR%4==1' | wc -l)

    log "GPU benchmark $LABEL ($NREADS reads)..."
    mkdir -p "out_gpu_${LABEL}"

    for RUN in 1 2 3; do
        START=$(date +%s%3N)
        gpu-kallisto quant \
            -i human_index.idx \
            -o "out_gpu_${LABEL}/run_${RUN}" \
            -l 175 -s 25 \
            "$R1" "$R2" 2>/dev/null
        END=$(date +%s%3N)
        ELAPSED=$(( END - START ))
        echo "TIMING:gpu:${LABEL}:${NREADS}:${ELAPSED}"
    done
}

# Also run CPU kallisto on same instance for direct comparison
run_cpu_benchmark() {
    local SRR="$1"
    local LABEL="$2"
    local NREADS
    NREADS=$(zcat "${SRR}_1.fastq.gz" | awk 'NR%4==1' | wc -l)

    mkdir -p "out_cpu_${LABEL}"
    for RUN in 1 2 3; do
        START=$(date +%s%3N)
        kallisto quant \
            -i human_index.idx \
            -o "out_cpu_${LABEL}/run_${RUN}" \
            --threads "$THREADS" \
            -l 175 -s 25 \
            "${SRR}_1.fastq.gz" "${SRR}_2.fastq.gz" 2>/dev/null
        END=$(date +%s%3N)
        ELAPSED=$(( END - START ))
        echo "TIMING:cpu:${LABEL}:${NREADS}:${ELAPSED}"
    done
}

run_gpu_benchmark "$SMALL_SRR" "small"
run_gpu_benchmark "$LARGE_SRR" "large"
run_cpu_benchmark "$SMALL_SRR" "small"
run_cpu_benchmark "$LARGE_SRR" "large"

log "GPU benchmark complete."
GPUEOF

# ---- Main loop: SSH into each instance and run appropriate script ---------

wait_for_ssh() {
    local IP="$1"
    local MAX=30
    local N=0
    while ! ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -i "$KEY" "ubuntu@$IP" "echo ok" &>/dev/null; do
        N=$(( N + 1 ))
        if [ "$N" -ge "$MAX" ]; then
            echo "Timeout waiting for SSH on $IP"
            return 1
        fi
        sleep 10
    done
}

get_ip() {
    local ID="$1"
    aws ec2 describe-instances \
        --instance-ids "$ID" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text
}

INSTANCES=()
while IFS= read -r line; do
    INSTANCES+=("$line")
done < <(jq -c '.[]' "$INSTANCE_JSON")

for INST_JSON in "${INSTANCES[@]}"; do
    ID=$(echo "$INST_JSON" | jq -r '.id')
    NAME=$(echo "$INST_JSON" | jq -r '.name')
    ROLE=$(echo "$INST_JSON" | jq -r '.role')
    ITYPE=$(echo "$INST_JSON" | jq -r '.instance_type')

    echo ""
    echo "========================================="
    echo "Setting up $NAME ($ID, $ROLE)"
    echo "========================================="

    IP=$(get_ip "$ID")
    echo "IP: $IP"

    echo "Waiting for SSH..."
    wait_for_ssh "$IP"
    echo "SSH ready. Waiting for user-data bootstrap to finish..."
    until ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            -i "$KEY" "ubuntu@$IP" "test -f /tmp/bootstrap_done" 2>/dev/null; do
        sleep 15
    done
    echo "Bootstrap complete."

    # Export SRR variables into the script
    BENCH_SCRIPT_WITH_VARS="export SMALL_SRR='$SMALL_SRR'
export LARGE_SRR='$LARGE_SRR'
"
    if [[ "$ROLE" == "cpu" ]]; then
        BENCH_SCRIPT_WITH_VARS+="$CPU_BENCH_SCRIPT"
    else
        BENCH_SCRIPT_WITH_VARS+="$GPU_BENCH_SCRIPT"
    fi

    # Upload benchmark script (separate from launch so SSH flushes stdin before exiting)
    echo "$BENCH_SCRIPT_WITH_VARS" | ssh \
        -o StrictHostKeyChecking=no \
        -i "$KEY" \
        "ubuntu@$IP" \
        "cat > /tmp/benchmark.sh && chmod +x /tmp/benchmark.sh"

    # Launch benchmark in background (nohup so SSH disconnect doesn't kill it)
    ssh -n \
        -o StrictHostKeyChecking=no \
        -i "$KEY" \
        "ubuntu@$IP" \
        "nohup bash /tmp/benchmark.sh > /tmp/bench_output.log 2>&1 &"

    echo "Benchmark started on $NAME. Output: /tmp/bench_output.log"
done

echo ""
echo "Benchmark started on all instances. Waiting for completion..."
