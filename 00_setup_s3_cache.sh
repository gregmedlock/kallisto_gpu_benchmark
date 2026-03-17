#!/usr/bin/env bash
# =============================================================================
# 00_setup_s3_cache.sh
# Create an S3 bucket and IAM instance profile so EC2 instances can cache
# benchmark data (FASTQ files + index) in S3 for fast reuse across instances.
# Run once before launching instances.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/config.local.sh" ]; then
    source "$SCRIPT_DIR/config.local.sh"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="kallisto-bench-cache-${ACCOUNT_ID}"
ROLE_NAME="kallisto-bench-s3"
PROFILE_NAME="kallisto-bench-s3"
REGION="us-east-1"

# ---- Create S3 bucket (idempotent) ----------------------------------------
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "Bucket s3://$BUCKET already exists."
else
    echo "Creating bucket s3://$BUCKET..."
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
fi

# ---- Create IAM role + instance profile (idempotent) ----------------------
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::${BUCKET}", "arn:aws:s3:::${BUCKET}/*"]
  }]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
    echo "IAM role $ROLE_NAME already exists."
else
    echo "Creating IAM role $ROLE_NAME..."
    aws iam create-role --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" --output text
fi

echo "Updating S3 access policy..."
aws iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name s3-cache-access \
    --policy-document "$S3_POLICY"

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" &>/dev/null; then
    echo "Instance profile $PROFILE_NAME already exists."
else
    echo "Creating instance profile $PROFILE_NAME..."
    aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME"
    aws iam add-role-to-instance-profile \
        --instance-profile-name "$PROFILE_NAME" \
        --role-name "$ROLE_NAME"
    echo "Waiting 10s for IAM propagation..."
    sleep 10
fi

# ---- Attach to any running instances --------------------------------------
INSTANCE_JSON="$SCRIPT_DIR/results/instance_ids.json"
if [ -f "$INSTANCE_JSON" ]; then
    echo ""
    echo "Attaching instance profile to running instances..."
    while IFS= read -r line; do
        ID=$(echo "$line" | jq -r '.id')
        NAME=$(echo "$line" | jq -r '.name')
        # Check if already associated
        ASSOC=$(aws ec2 describe-iam-instance-profile-associations \
            --filters "Name=instance-id,Values=$ID" "Name=state,Values=associated" \
            --query 'IamInstanceProfileAssociations[0].IamInstanceProfile.Arn' \
            --output text 2>/dev/null || echo "None")
        if [[ "$ASSOC" == *"$PROFILE_NAME"* ]]; then
            echo "  $NAME ($ID): already attached"
        else
            echo "  $NAME ($ID): attaching..."
            aws ec2 associate-iam-instance-profile \
                --instance-id "$ID" \
                --iam-instance-profile Name="$PROFILE_NAME" 2>/dev/null || \
                echo "    (may already have a profile — detach first if needed)"
        fi
    done < <(jq -c '.[]' "$INSTANCE_JSON")
fi

# ---- Save bucket name to config.local.sh ----------------------------------
if grep -q 'S3_CACHE_BUCKET=' "$SCRIPT_DIR/config.local.sh"; then
    sed -i.bak "s|^S3_CACHE_BUCKET=.*|S3_CACHE_BUCKET=\"$BUCKET\"|" "$SCRIPT_DIR/config.local.sh"
    rm -f "$SCRIPT_DIR/config.local.sh.bak"
else
    echo "S3_CACHE_BUCKET=\"$BUCKET\"" >> "$SCRIPT_DIR/config.local.sh"
fi

echo ""
echo "Done. S3 cache bucket: s3://$BUCKET"
echo "Instance profile: $PROFILE_NAME"
echo ""
echo "To upload existing data from a CPU instance:"
echo "  ssh -i ~/.ssh/kallisto-bench.pem ubuntu@<IP> \\"
echo "    'cd ~/kallisto_bench && aws s3 sync . s3://$BUCKET/bench_data/ --exclude \"*\" --include \"*.fastq.gz\" --include \"human_index.idx\"'"
