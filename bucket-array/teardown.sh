#!/usr/bin/env zsh
set -euo pipefail

STACK_NAME="cloudformation-bucket-array"

echo "Deleting stack: $STACK_NAME"
aws cloudformation delete-stack --stack-name "$STACK_NAME"

echo "Waiting for stack deletion..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME"
echo "Stack deleted successfully."
