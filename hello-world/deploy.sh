#!/usr/bin/env zsh
set -euo pipefail

STACK_NAME="cloudformation-hello-world"
ENVIRONMENT="${1:-dev}"

aws cloudformation deploy \
  --template-file hello-world.yaml \
  --stack-name "$STACK_NAME" \
  --parameter-overrides Environment="$ENVIRONMENT" \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table

# Curl lambda:
# curl https://7znepikih3.execute-api.us-west-2.amazonaws.com/
