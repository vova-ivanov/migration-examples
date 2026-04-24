#!/usr/bin/env zsh
set -euo pipefail

STACK_NAME="dynamic-resources-app"
ENVIRONMENT="${1:-dev}"

aws cloudformation deploy \
  --template-file dynamic-resources-app.yaml \
  --stack-name "$STACK_NAME" \
  --parameter-overrides Environment="$ENVIRONMENT" \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table

echo ""
echo "Watch the toggle (runs every 5 minutes via EventBridge Scheduler):"
echo "  curl <StatusEndpoint>    # shows which resource is currently allocated"
echo "  curl <ApiEndpoint>       # served by the active resource"
