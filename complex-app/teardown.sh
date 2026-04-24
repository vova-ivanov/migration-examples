#!/usr/bin/env zsh
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./teardown.sh [environment]
#
#   Empties all application S3 buckets (including versioned objects), then
#   deletes the CloudFormation stack and waits for completion.
#
# ── Examples ──────────────────────────────────────────────────────────────────
#
#   ./teardown.sh
#   ./teardown.sh staging
#
# ─────────────────────────────────────────────────────────────────────────────

ENVIRONMENT="${1:-dev}"
STACK_NAME="${STACK_NAME:-cloudformation-complex-app-${ENVIRONMENT}}"

# ── Helpers ───────────────────────────────────────────────────────────────────

empty_bucket() {
  local bucket="$1"

  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "  Bucket not found, skipping: $bucket"
    return
  fi

  echo "  Emptying: $bucket"

  # Delete all current objects
  aws s3 rm "s3://${bucket}" --recursive --quiet

  # Delete all versioned objects and delete markers (for versioned buckets)
  local versions
  versions=$(aws s3api list-object-versions --bucket "$bucket" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{"Objects": null}')

  local obj_count
  obj_count=$(echo "$versions" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(len(d.get('Objects') or []))")

  if [[ "$obj_count" -gt 0 ]]; then
    echo "    Deleting $obj_count versioned objects..."
    echo "$versions" | python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
objects = data.get('Objects') or []
for i in range(0, len(objects), 1000):
    batch = {'Objects': objects[i:i+1000], 'Quiet': True}
    cmd = ['aws', 's3api', 'delete-objects',
           '--bucket', '${bucket}',
           '--delete', json.dumps(batch)]
    subprocess.run(cmd, check=True, capture_output=True)
"
  fi

  # Delete all delete markers
  local markers
  markers=$(aws s3api list-object-versions --bucket "$bucket" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
    --output json 2>/dev/null || echo '{"Objects": null}')

  local marker_count
  marker_count=$(echo "$markers" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(len(d.get('Objects') or []))")

  if [[ "$marker_count" -gt 0 ]]; then
    echo "    Deleting $marker_count delete markers..."
    echo "$markers" | python3 -c "
import json, sys, subprocess
data = json.load(sys.stdin)
objects = data.get('Objects') or []
for i in range(0, len(objects), 1000):
    batch = {'Objects': objects[i:i+1000], 'Quiet': True}
    cmd = ['aws', 's3api', 'delete-objects',
           '--bucket', '${bucket}',
           '--delete', json.dumps(batch)]
    subprocess.run(cmd, check=True, capture_output=True)
"
  fi

  echo "  Done: $bucket"
}

# ── Resolve account / region ──────────────────────────────────────────────────

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}}"
REGION="${REGION:-us-east-1}"
DEPLOY_BUCKET="cfn-deploy-${ACCOUNT_ID}-${REGION}"

# ── Empty S3 buckets before stack deletion ────────────────────────────────────
# CloudFormation cannot delete non-empty buckets, so we empty them first.

echo "Emptying S3 buckets for environment: ${ENVIRONMENT}"

# Try to get bucket names from stack outputs first; fall back to naming convention
get_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
    --output text 2>/dev/null || echo ""
}

ASSETS_BUCKET=$(get_output AssetsBucketName)
[[ -z "$ASSETS_BUCKET" || "$ASSETS_BUCKET" == "None" ]] && \
  ASSETS_BUCKET="app-assets-${ENVIRONMENT}-${ACCOUNT_ID}"

LOGS_BUCKET="app-logs-${ENVIRONMENT}-${ACCOUNT_ID}"
DEPLOYMENTS_BUCKET="app-deployments-${ENVIRONMENT}-${ACCOUNT_ID}"

empty_bucket "$ASSETS_BUCKET"
empty_bucket "$LOGS_BUCKET"
empty_bucket "$DEPLOYMENTS_BUCKET"

# ── Remove stale packaged templates from the deploy bucket ───────────────────
# Clears the complex-app/ prefix so the next deploy uploads a clean set.

if aws s3api head-bucket --bucket "$DEPLOY_BUCKET" 2>/dev/null; then
  echo "  Removing stale artifacts from s3://${DEPLOY_BUCKET}/complex-app/"
  aws s3 rm "s3://${DEPLOY_BUCKET}/complex-app/" --recursive --quiet || true
fi

# ── Delete the CloudFormation stack ──────────────────────────────────────────

echo ""

STACK_STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].StackStatus' \
  --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [[ "$STACK_STATUS" == "DOES_NOT_EXIST" ]]; then
  echo "Stack does not exist, nothing to delete: ${STACK_NAME}"
else
  echo "Deleting stack: ${STACK_NAME}  (current status: ${STACK_STATUS})"
  aws cloudformation delete-stack --stack-name "$STACK_NAME"

  echo "Waiting for deletion to complete (this may take several minutes)..."
  if ! aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null; then
    FINAL_STATUS=$(aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" \
      --query 'Stacks[0].StackStatus' \
      --output text 2>/dev/null || echo "DELETED")
    if [[ "$FINAL_STATUS" != "DELETED" && "$FINAL_STATUS" != "" ]]; then
      echo "Error: stack deletion failed with status: ${FINAL_STATUS}" >&2
      exit 1
    fi
  fi

  echo ""
  echo "Stack deleted successfully: ${STACK_NAME}"
fi
