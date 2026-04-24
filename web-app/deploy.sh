#!/usr/bin/env zsh
set -euo pipefail

STACK_NAME="cloudformation-web-app"
ENVIRONMENT="${1:-dev}"

aws cloudformation deploy \
  --template-file web-app.yaml \
  --stack-name "$STACK_NAME" \
  --parameter-overrides Environment="$ENVIRONMENT" \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table

# Post items:
# curl -X POST https://1cx1vdd8a9.execute-api.us-west-2.amazonaws.com/dev/items -H "Content-Type: application/json" -d '{"name": "test item"}'

# Read items:
# curl https://1cx1vdd8a9.execute-api.us-west-2.amazonaws.com/dev/items
