#!/usr/bin/env zsh
set -euo pipefail

ENVIRONMENT="${1:-dev}"
ROLE_NAME="hello-world-unmanaged-iamrole-${ENVIRONMENT}"
FUNCTION_NAME="hello-world-unmanaged-lambda-${ENVIRONMENT}"
API_NAME="hello-world-unmanaged-api-${ENVIRONMENT}"

echo "Looking up API Gateway: $API_NAME"
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" \
  --output text 2>/dev/null || echo "")

if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  echo "Deleting API Gateway: $API_ID"
  aws apigatewayv2 delete-api --api-id "$API_ID"
fi

echo "Deleting Lambda function: $FUNCTION_NAME"
aws lambda delete-function --function-name "$FUNCTION_NAME" 2>/dev/null || true

# Clean up any leftover function URL from old deploys
echo "Cleaning up any function URL..."
aws lambda delete-function-url-config --function-name "$FUNCTION_NAME" 2>/dev/null || true

echo "Detaching policy from role: $ROLE_NAME"
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true

echo "Deleting IAM role: $ROLE_NAME"
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true

echo "Teardown complete."
