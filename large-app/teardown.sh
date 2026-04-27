#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${STACK_NAME:-large-app}"
REGION="${AWS_REGION:-us-west-2}"

echo "=== Large App CloudFormation Teardown ==="
echo "Stack:  $STACK_NAME"
echo "Region: $REGION"
echo ""

echo "--- Deleting stack ---"
aws cloudformation delete-stack \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "Waiting for stack deletion to complete..."
aws cloudformation wait stack-delete-complete \
  --stack-name "$STACK_NAME" \
  --region "$REGION"

echo "Stack $STACK_NAME deleted successfully."

# The VPC flow log can recreate its log group momentarily after CFN deletes it.
# Explicitly remove it so the next deploy doesn't hit the EarlyValidation conflict check.
ENV="${ENV:-dev}"
LOG_GROUP="/aws/vpc/flowlogs-${ENV}"
if aws logs describe-log-groups \
     --log-group-name-prefix "$LOG_GROUP" \
     --region "$REGION" \
     --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" \
     --output text 2>/dev/null | grep -q .; then
  echo "Removing residual log group: $LOG_GROUP"
  aws logs delete-log-group --log-group-name "$LOG_GROUP" --region "$REGION"
fi
