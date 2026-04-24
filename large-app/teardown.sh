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
