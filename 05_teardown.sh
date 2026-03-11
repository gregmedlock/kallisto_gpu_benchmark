#!/usr/bin/env bash
# =============================================================================
# 05_teardown.sh
# Terminate all benchmark instances. Run this when done to stop billing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
INSTANCE_JSON="$RESULTS_DIR/instance_ids.json"

if [ ! -f "$INSTANCE_JSON" ]; then
    echo "No instance_ids.json found. Nothing to terminate."
    exit 0
fi

INSTANCE_IDS=$(jq -r '.[].id' "$INSTANCE_JSON" | tr '\n' ' ')

echo "Instances to terminate:"
jq -r '.[] | "  \(.name) (\(.id))"' "$INSTANCE_JSON"
echo ""
read -r -p "Type 'yes' to confirm termination: " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

# shellcheck disable=SC2086
aws ec2 terminate-instances --instance-ids $INSTANCE_IDS \
    --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' \
    --output table

echo ""
echo "Instances terminated. Verify in the EC2 console:"
echo "  https://console.aws.amazon.com/ec2/v2/home#Instances"
echo ""
echo "To also delete the security group and key pair:"
echo "  aws ec2 delete-security-group --group-id <SG_ID>"
echo "  aws ec2 delete-key-pair --key-name kallisto-bench"
echo "  rm ~/.ssh/kallisto-bench.pem"
