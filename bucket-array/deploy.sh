#!/usr/bin/env zsh
set -euo pipefail

STACK_NAME="cloudformation-bucket-array"
BUCKET_COUNT="${1:-3}"

aws cloudformation deploy \
  --template-file bucket-array.yaml \
  --stack-name "$STACK_NAME" \
  --parameter-overrides BucketCount="$BUCKET_COUNT"

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table
