#!/usr/bin/env zsh
set -euo pipefail

ENVIRONMENT="${1:-dev}"
STACK_NAME="mixed-unmanaged-infra-${ENVIRONMENT}"
PREFIX="mixed-unmanaged-${ENVIRONMENT}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-west-2")

API_FUNCTION="${PREFIX}-api"
WORKER_FUNCTION="${PREFIX}-worker"
ROLE_NAME="${PREFIX}-lambda-role"
API_NAME="${PREFIX}-api"

echo "==> API Gateway: $API_NAME"
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" \
  --output text 2>/dev/null || echo "")
if [[ -n "$API_ID" && "$API_ID" != "None" ]]; then
  aws apigatewayv2 delete-api --api-id "$API_ID"
  echo "Deleted API: $API_ID"
fi

echo "==> SQS event source mappings for: $WORKER_FUNCTION"
MAPPING_UUIDS=$(aws lambda list-event-source-mappings \
  --function-name "$WORKER_FUNCTION" \
  --query "EventSourceMappings[].UUID" \
  --output text 2>/dev/null || echo "")
for UUID in $MAPPING_UUIDS; do
  [[ -n "$UUID" && "$UUID" != "None" ]] && \
    aws lambda delete-event-source-mapping --uuid "$UUID" 2>/dev/null || true
done

echo "==> Lambda: $API_FUNCTION"
aws lambda delete-function --function-name "$API_FUNCTION" 2>/dev/null || true

echo "==> Lambda: $WORKER_FUNCTION"
aws lambda delete-function --function-name "$WORKER_FUNCTION" 2>/dev/null || true

echo "==> IAM: $ROLE_NAME"
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${PREFIX}-resource-access" 2>/dev/null || true
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true

# Empty the versioned S3 bucket before deleting the CloudFormation stack.
# aws s3 rm --recursive only removes current object versions; versioned buckets
# also accumulate delete markers and non-current versions that must be removed
# explicitly before CloudFormation can delete the bucket.
BUCKET_NAME="mixed-unmanaged-${ENVIRONMENT}-assets-${ACCOUNT_ID}"
echo "==> Emptying versioned S3 bucket: $BUCKET_NAME"
aws s3api list-object-versions --bucket "$BUCKET_NAME" \
  --query 'Versions[].{Key:Key,VersionId:VersionId}' \
  --output json 2>/dev/null \
| python3 -c '
import json, sys, subprocess
versions = json.load(sys.stdin) or []
for chunk in [versions[i:i+1000] for i in range(0, max(len(versions),1), 1000)]:
    if chunk:
        payload = json.dumps({"Objects": chunk, "Quiet": True})
        subprocess.run(["aws","s3api","delete-objects",
                        "--bucket","'"$BUCKET_NAME"'",
                        "--delete",payload], check=True)
' 2>/dev/null || true
aws s3api list-object-versions --bucket "$BUCKET_NAME" \
  --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
  --output json 2>/dev/null \
| python3 -c '
import json, sys, subprocess
markers = json.load(sys.stdin) or []
for chunk in [markers[i:i+1000] for i in range(0, max(len(markers),1), 1000)]:
    if chunk:
        payload = json.dumps({"Objects": chunk, "Quiet": True})
        subprocess.run(["aws","s3api","delete-objects",
                        "--bucket","'"$BUCKET_NAME"'",
                        "--delete",payload], check=True)
' 2>/dev/null || true

echo "==> Deleting CloudFormation stack: $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME"
echo "Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"

echo "Teardown complete."
