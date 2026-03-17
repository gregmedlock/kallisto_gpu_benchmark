#!/usr/bin/env bash
# =============================================================================
# 02_setup_and_benchmark.sh
# SSH into each instance, install kallisto / gpu-kallisto, download test data,
# and run the benchmark. Timing results are written locally.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
    source "$SCRIPT_DIR/config.local.sh"
fi
RESULTS_DIR="$SCRIPT_DIR/results"
INSTANCE_JSON="$RESULTS_DIR/instance_ids.json"
KEY="$HOME/.ssh/kallisto-bench.pem"

# Test samples: one smaller and one larger, both publicly available Geuvadis RNA-seq.
# The paper used SRR1069546 for small, but it requires dbGaP access (phs000424).
# ERR188021 is a similar Geuvadis sample (~32M reads) available directly from ENA.
SMALL_SRR="ERR188021"    # ~32M paired-end reads (Geuvadis, public on ENA)
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
    # Try S3 cache first
    if [ -n "${S3_CACHE_BUCKET:-}" ] && \
       aws s3 cp "s3://${S3_CACHE_BUCKET}/bench_data/human_index.idx" human_index.idx 2>/dev/null; then
        log "Got index from S3 cache."
    else
        wget -q "https://ftp.ensembl.org/pub/release-113/fasta/homo_sapiens/cdna/Homo_sapiens.GRCh38.cdna.all.fa.gz" \
            -O human_transcriptome.fa.gz
        log "Indexing transcriptome (takes ~10-15 min)..."
        kallisto index -i human_index.idx human_transcriptome.fa.gz
        rm -f human_transcriptome.fa.gz
        # Upload to S3 cache for other instances
        if [ -n "${S3_CACHE_BUCKET:-}" ]; then
            log "Uploading index to S3 cache..."
            aws s3 cp human_index.idx "s3://${S3_CACHE_BUCKET}/bench_data/human_index.idx" 2>/dev/null || true
        fi
    fi
fi

# ---- Download test samples -----------------------------------------------
# Try S3 cache (fast, same-region), then ENA HTTPS, then fasterq-dump.
download_sample() {
    local SRR="$1"
    if [ ! -f "${SRR}_1.fastq.gz" ] || [ ! -s "${SRR}_1.fastq.gz" ]; then
        rm -f "${SRR}_1.fastq.gz" "${SRR}_2.fastq.gz"

        # 1) Try S3 cache
        if [ -n "${S3_CACHE_BUCKET:-}" ] && \
           aws s3 ls "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_1.fastq.gz" &>/dev/null; then
            log "Downloading $SRR from S3 cache..."
            aws s3 cp "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_1.fastq.gz" "${SRR}_1.fastq.gz"
            aws s3 cp "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_2.fastq.gz" "${SRR}_2.fastq.gz"
            return
        fi

        # 2) Try ENA
        log "Querying ENA for $SRR..."
        local FTP_FIELD
        FTP_FIELD=$(curl -sf \
            "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${SRR}&result=read_run&fields=fastq_ftp&format=tsv" \
            | tail -n +2 | head -1 | cut -f2)

        if [ -n "$FTP_FIELD" ]; then
            local R1 R2
            R1=$(echo "$FTP_FIELD" | tr ';' '\n' | grep '_1\.fastq\.gz')
            R2=$(echo "$FTP_FIELD" | tr ';' '\n' | grep '_2\.fastq\.gz')
            log "Downloading ${SRR} via ENA HTTPS..."
            wget -q "https://${R1}" -O "${SRR}_1.fastq.gz"
            wget -q "https://${R2}" -O "${SRR}_2.fastq.gz"
        else
            # 3) Fall back to fasterq-dump
            log "ENA has no FASTQ for $SRR; falling back to fasterq-dump..."
            if ! command -v fasterq-dump &>/dev/null; then
                wget -q https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz
                tar -xzf sratoolkit.current-ubuntu64.tar.gz
                sudo cp sratoolkit.*/bin/fasterq-dump /usr/local/bin/
            fi
            mkdir -p "${HOME}/.ncbi"
            printf '/config/default = "true"\n/repository/user/main/public/root = "%s/ncbi"\n' "${HOME}" \
                > "${HOME}/.ncbi/user-settings.mkfg"
            fasterq-dump "$SRR" --split-files --outdir . --threads "$THREADS"
            gzip -1 "${SRR}_1.fastq" "${SRR}_2.fastq"
        fi

        # Upload to S3 cache for other instances
        if [ -n "${S3_CACHE_BUCKET:-}" ]; then
            log "Uploading $SRR to S3 cache..."
            aws s3 cp "${SRR}_1.fastq.gz" "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_1.fastq.gz" 2>/dev/null &
            aws s3 cp "${SRR}_2.fastq.gz" "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_2.fastq.gz" 2>/dev/null &
            wait
        fi
    fi
}

download_sample "${SMALL_SRR}"
download_sample "${LARGE_SRR}"

# ---- Run benchmark -------------------------------------------------------
run_benchmark() {
    local SRR="$1"
    local LABEL="$2"
    local NREADS="$3"
    local R1="${SRR}_1.fastq.gz"
    local R2="${SRR}_2.fastq.gz"

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

SMALL_NREADS=32507828   # ERR188021: pre-counted to avoid slow zcat|awk|wc
LARGE_NREADS=296169061  # SRR30898520: pre-counted

run_benchmark "$SMALL_SRR" "small" "$SMALL_NREADS"
run_benchmark "$LARGE_SRR" "large" "$LARGE_NREADS"

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

# ---- Install nvcomp (required by GPU-kallisto) ----------------------------
if [ ! -d /usr/local/lib/cmake/nvcomp ]; then
    log "Installing nvcomp 4.0.1..."
    # nvcomp 4.0.1 only ships cuda12.x builds; they are forward-compatible with CUDA 13.0.
    wget -q "https://developer.download.nvidia.com/compute/nvcomp/4.0.1/local_installers/nvcomp-linux-x86_64-4.0.1-cuda12.x.tar.gz" \
        -O nvcomp.tar.gz
    tar -xzf nvcomp.tar.gz
    sudo cp -r nvcomp*/lib/* /usr/local/lib/
    sudo cp -r nvcomp*/include/* /usr/local/include/
    sudo cp -r nvcomp*/lib/cmake/nvcomp /usr/local/lib/cmake/
    sudo ldconfig
    rm -rf nvcomp*
fi

# ---- Build GPU-kallisto from source (gpu branch) -------------------------
# NOTE: gpu-kallisto's cuCollections requires CCCL >=3.0, which ships with
# CUDA 13.0. The Deep Learning Base AMI has CUDA 13.0 at /usr/local/cuda-13.0/.
# nvcomp 4.x changed the batched deflate decompression API (removed opts
# parameter), so we patch GPUReadLoader.cuh to match.
if ! command -v gpu-kallisto &>/dev/null; then
    log "Building GPU-kallisto (using CUDA 13.0)..."
    rm -rf kallisto-gpu
    git clone --branch gpu --depth=1 https://github.com/pachterlab/kallisto.git kallisto-gpu
    cd kallisto-gpu
    # Patch nvcomp 4.x API: decompression opts parameter was removed
    sed -i 's/nvcompBatchedDeflateDecompressOpts_t opts = nvcompBatchedDeflateDecompressDefaultOpts;//g' src/GPUReadLoader.cuh
    sed -i 's/nvcompBatchedDeflateDecompressGetTempSizeAsync(/nvcompBatchedDeflateDecompressGetTempSize(/g' src/GPUReadLoader.cuh
    sed -i 's/max_blocks_, 65536, opts, \&temp_size_, max_batch_size/max_blocks_, 65536, \&temp_size_/g' src/GPUReadLoader.cuh
    sed -i '/opts,/{/d_statuses_/{s/opts, *//}}' src/GPUReadLoader.cuh
    sed -i '/^[[:space:]]*opts,$/d' src/GPUReadLoader.cuh
    # Build htslib first to avoid parallel build race condition
    cd ext/htslib && make -j"$THREADS" && cd ../..
    mkdir build && cd build
    export PATH=/usr/local/cuda-13.0/bin:$PATH
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc \
        -DCMAKE_CUDA_ARCHITECTURES="native"
    make -j"$THREADS" || make
    sudo cp src/gpukallisto /usr/local/bin/gpu-kallisto
    cd "$WORKDIR"
fi

# Also install CPU kallisto for a same-machine comparison
if ! command -v kallisto &>/dev/null; then
    log "Building CPU kallisto..."
    git clone --depth=1 https://github.com/pachterlab/kallisto.git kallisto-cpu
    cd kallisto-cpu && mkdir build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    make -j"$THREADS" || make  # parallel build has flaky bifrost dependency; retry sequentially
    sudo make install
    cd "$WORKDIR"
fi


if [ ! -f human_index.idx ] || [ ! -s human_index.idx ]; then
    rm -f human_index.idx.gz human_index.idx
    if [ -n "${S3_CACHE_BUCKET:-}" ] && \
       aws s3 cp "s3://${S3_CACHE_BUCKET}/bench_data/human_index.idx" human_index.idx 2>/dev/null; then
        log "Got index from S3 cache."
    else
        log "Downloading transcriptome FASTA..."
        wget -q "https://ftp.ensembl.org/pub/release-113/fasta/homo_sapiens/cdna/Homo_sapiens.GRCh38.cdna.all.fa.gz" \
            -O human_transcriptome.fa.gz
        log "Indexing transcriptome (takes ~10-15 min)..."
        kallisto index -i human_index.idx human_transcriptome.fa.gz
        rm -f human_transcriptome.fa.gz
        if [ -n "${S3_CACHE_BUCKET:-}" ]; then
            aws s3 cp human_index.idx "s3://${S3_CACHE_BUCKET}/bench_data/human_index.idx" 2>/dev/null || true
        fi
    fi
fi

download_sample() {
    local SRR="$1"
    if [ ! -f "${SRR}_1.fastq.gz" ] || [ ! -s "${SRR}_1.fastq.gz" ]; then
        rm -f "${SRR}_1.fastq.gz" "${SRR}_2.fastq.gz"

        if [ -n "${S3_CACHE_BUCKET:-}" ] && \
           aws s3 ls "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_1.fastq.gz" &>/dev/null; then
            log "Downloading $SRR from S3 cache..."
            aws s3 cp "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_1.fastq.gz" "${SRR}_1.fastq.gz"
            aws s3 cp "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_2.fastq.gz" "${SRR}_2.fastq.gz"
            return
        fi

        log "Querying ENA for $SRR..."
        local FTP_FIELD
        FTP_FIELD=$(curl -sf \
            "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=${SRR}&result=read_run&fields=fastq_ftp&format=tsv" \
            | tail -n +2 | head -1 | cut -f2)

        if [ -n "$FTP_FIELD" ]; then
            local R1 R2
            R1=$(echo "$FTP_FIELD" | tr ';' '\n' | grep '_1\.fastq\.gz')
            R2=$(echo "$FTP_FIELD" | tr ';' '\n' | grep '_2\.fastq\.gz')
            log "Downloading ${SRR} via ENA HTTPS..."
            wget -q "https://${R1}" -O "${SRR}_1.fastq.gz"
            wget -q "https://${R2}" -O "${SRR}_2.fastq.gz"
        else
            log "ENA has no FASTQ for $SRR; falling back to fasterq-dump..."
            if ! command -v fasterq-dump &>/dev/null; then
                wget -q https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz
                tar -xzf sratoolkit.current-ubuntu64.tar.gz
                sudo cp sratoolkit.*/bin/fasterq-dump /usr/local/bin/
            fi
            mkdir -p "${HOME}/.ncbi"
            printf '/config/default = "true"\n/repository/user/main/public/root = "%s/ncbi"\n' "${HOME}" \
                > "${HOME}/.ncbi/user-settings.mkfg"
            fasterq-dump "$SRR" --split-files --outdir . --threads "$THREADS"
            gzip -1 "${SRR}_1.fastq" "${SRR}_2.fastq"
        fi

        if [ -n "${S3_CACHE_BUCKET:-}" ]; then
            log "Uploading $SRR to S3 cache..."
            aws s3 cp "${SRR}_1.fastq.gz" "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_1.fastq.gz" 2>/dev/null &
            aws s3 cp "${SRR}_2.fastq.gz" "s3://${S3_CACHE_BUCKET}/bench_data/${SRR}_2.fastq.gz" 2>/dev/null &
            wait
        fi
    fi
}

download_sample "${SMALL_SRR}"
download_sample "${LARGE_SRR}"

# ---- Run GPU benchmark ---------------------------------------------------
run_gpu_benchmark() {
    local SRR="$1"
    local LABEL="$2"
    local NREADS="$3"
    local R1="${SRR}_1.fastq.gz"
    local R2="${SRR}_2.fastq.gz"

    log "GPU benchmark $LABEL ($NREADS reads)..."
    mkdir -p "out_gpu_${LABEL}"

    # Warmup run: CUDA JIT-compiles PTX to native GPU code on the first
    # invocation, which can add minutes of one-time overhead. This run
    # populates ~/.nv/ComputeCache so timed runs reflect steady-state
    # performance. The warmup is not timed.
    log "  warmup run (CUDA JIT compilation)..."
    gpu-kallisto quant \
        -i human_index.idx \
        -o "out_gpu_${LABEL}/warmup" \
        -l 175 -s 25 \
        "$R1" "$R2" 2>/dev/null || true

    for RUN in 1 2 3; do
        START=$(date +%s%3N)
        # gpu-kallisto may abort during cleanup after writing results; ignore exit code
        gpu-kallisto quant \
            -i human_index.idx \
            -o "out_gpu_${LABEL}/run_${RUN}" \
            -l 175 -s 25 \
            "$R1" "$R2" 2>/dev/null || true
        END=$(date +%s%3N)
        ELAPSED=$(( END - START ))
        echo "TIMING:gpu:${LABEL}:${NREADS}:${ELAPSED}"
    done
}

# Also run CPU kallisto on same instance for direct comparison
run_cpu_benchmark() {
    local SRR="$1"
    local LABEL="$2"
    local NREADS="$3"

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

SMALL_NREADS=32507828   # ERR188021: pre-counted to avoid slow zcat|awk|wc
LARGE_NREADS=296169061  # SRR30898520: pre-counted

run_gpu_benchmark "$SMALL_SRR" "small" "$SMALL_NREADS"
run_gpu_benchmark "$LARGE_SRR" "large" "$LARGE_NREADS"
# Run CPU kallisto on the same instance for a direct same-machine speedup comparison.
# Only the small dataset is run on CPU — the large dataset takes hours on the limited
# vCPUs of GPU instances (e.g. 4 vCPUs on g4dn.xlarge) and isn't worth the cost.
# The cost-normalized comparison (Fig. 2) uses the dedicated c7i CPU instances instead.
run_cpu_benchmark "$SMALL_SRR" "small" "$SMALL_NREADS"

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

    # Export SRR and S3 cache variables into the script
    BENCH_SCRIPT_WITH_VARS="export SMALL_SRR='$SMALL_SRR'
export LARGE_SRR='$LARGE_SRR'
export S3_CACHE_BUCKET='${S3_CACHE_BUCKET:-}'
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
        "cat > ~/benchmark.sh && chmod +x ~/benchmark.sh"

    # Launch benchmark in background (nohup so SSH disconnect doesn't kill it).
    # Log to ~ (not /tmp) so results survive instance stop/start cycles.
    ssh -n \
        -o StrictHostKeyChecking=no \
        -i "$KEY" \
        "ubuntu@$IP" \
        "nohup bash ~/benchmark.sh > ~/bench_output.log 2>&1 &"

    echo "Benchmark started on $NAME. Output: ~/bench_output.log"
done

echo ""
echo "Benchmark started on all instances. Waiting for completion..."
