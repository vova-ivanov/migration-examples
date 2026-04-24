#!/usr/bin/env zsh
set -euo pipefail

STACK_NAME="cloudformation-web-app"

# Empty the S3 assets bucket before deleting the stack
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
  --output text 2>/dev/null || echo "")

if [[ -n "$BUCKET_NAME" && "$BUCKET_NAME" != "None" ]]; then
  echo "Emptying bucket: $BUCKET_NAME"
  aws s3 rm "s3://$BUCKET_NAME" --recursive
fi

echo "Deleting stack: $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME"

echo "Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
echo "Stack deleted successfully."
