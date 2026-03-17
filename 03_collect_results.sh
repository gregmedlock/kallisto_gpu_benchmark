#!/usr/bin/env bash
# =============================================================================
# 03_collect_results.sh
# Poll instances and download timing results when benchmarks complete.
# Usage:
#   bash scripts/03_collect_results.sh           # collect once (may be partial)
#   bash scripts/03_collect_results.sh --watch   # poll every 60s until all done
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
INSTANCE_JSON="$RESULTS_DIR/instance_ids.json"
KEY="$HOME/.ssh/kallisto-bench.pem"
WATCH=false

[[ "${1:-}" == "--watch" ]] && WATCH=true

get_ip() {
    aws ec2 describe-instances \
        --instance-ids "$1" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text
}

collect_from_instance() {
    local ID="$1"
    local NAME="$2"
    local ROLE="$3"
    local ITYPE="$4"
    local PRICE="$5"
    local IP

    IP=$(get_ip "$ID")
    if [[ "$IP" == "None" || -z "$IP" ]]; then
        echo "  $NAME: no IP yet, skipping"
        return 1
    fi

    # Check if benchmark is done
    if ssh -n -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        -i "$KEY" "ubuntu@$IP" \
        "grep -q 'benchmark complete' ~/bench_output.log 2>/dev/null"; then
        IS_DONE=1
    else
        IS_DONE=0
    fi

    if [[ "$IS_DONE" -eq 0 ]]; then
        LAST_LINE=$(ssh -n -o StrictHostKeyChecking=no -i "$KEY" "ubuntu@$IP" \
            "tail -1 ~/bench_output.log 2>/dev/null || echo 'not started'")
        echo "  $NAME: in progress — $LAST_LINE"
        return 1
    fi

    echo "  $NAME: DONE — collecting results"

    # Pull timing lines and construct JSON
    ssh -n -o StrictHostKeyChecking=no -i "$KEY" "ubuntu@$IP" \
        "grep '^TIMING:' ~/bench_output.log" \
        > "$RESULTS_DIR/raw_timing_${NAME}.txt" 2>/dev/null || true

    # Also grab the full log
    scp -o StrictHostKeyChecking=no -i "$KEY" \
        "ubuntu@$IP:~/bench_output.log" \
        "$RESULTS_DIR/full_log_${NAME}.log" 2>/dev/null || true

    # Parse timing lines and emit JSON
    python3 - << PYEOF
import json, sys

timings = []
with open("$RESULTS_DIR/raw_timing_${NAME}.txt") as f:
    for line in f:
        line = line.strip()
        if not line.startswith("TIMING:"):
            continue
        parts = line.split(":")
        # CPU format:  TIMING:<label>:<nreads>:<threads>:<ms>
        # GPU format:  TIMING:<tool>:<label>:<nreads>:<ms>
        if "$ROLE" == "cpu":
            _, label, nreads, threads, ms = parts
            tool = "cpu"
        else:
            _, tool, label, nreads, ms = parts
        timings.append({
            "instance_id": "$ID",
            "instance_name": "$NAME",
            "instance_type": "$ITYPE",
            "role": "$ROLE",
            "price_per_hr": float("$PRICE"),
            "tool": tool,
            "dataset": label,
            "n_reads": int(nreads),
            "wall_time_ms": int(ms),
        })

out = "$RESULTS_DIR/timing_${NAME}.json"
if not timings:
    print(f"  ERROR: 0 timing records for $NAME — benchmark may not have run correctly")
    raise SystemExit(1)
with open(out, "w") as f:
    json.dump(timings, f, indent=2)
print(f"  Wrote {len(timings)} timing records to {out}")
PYEOF
    return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do
    echo ""
    echo "[$(date)] Checking instance status..."
    PENDING=0

    INSTANCES=()
    while IFS= read -r line; do
        INSTANCES+=("$line")
    done < <(jq -c '.[]' "$INSTANCE_JSON")
    for INST_JSON in "${INSTANCES[@]}"; do
        ID=$(echo "$INST_JSON" | jq -r '.id')
        NAME=$(echo "$INST_JSON" | jq -r '.name')
        ROLE=$(echo "$INST_JSON" | jq -r '.role')
        ITYPE=$(echo "$INST_JSON" | jq -r '.instance_type')
        PRICE=$(echo "$INST_JSON" | jq -r '.price_per_hr')

        if [ -f "$RESULTS_DIR/timing_${NAME}.json" ]; then
            echo "  $NAME: already collected"
        else
            collect_from_instance "$ID" "$NAME" "$ROLE" "$ITYPE" "$PRICE" || PENDING=$(( PENDING + 1 ))
        fi
    done

    if [[ "$WATCH" == false ]] || [[ "$PENDING" -eq 0 ]]; then
        break
    fi

    echo ""
    echo "$PENDING instance(s) still running. Rechecking in 60s... (Ctrl+C to stop)"
    sleep 60
done

echo ""
echo "Collected files:"
ls "$RESULTS_DIR"/timing_*.json 2>/dev/null | xargs -I{} basename {}

echo ""
echo "Run the analysis:"
echo "  python3 scripts/04_analyze.py"
