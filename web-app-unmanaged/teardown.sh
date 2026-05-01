#!/usr/bin/env zsh
set -euo pipefail

ENVIRONMENT="${1:-dev}"
PREFIX="web-app-unmanaged-${ENVIRONMENT}"
TABLE_NAME="${PREFIX}-items"
ROLE_NAME="${PREFIX}-role"
FUNCTION_NAME="${PREFIX}-api"
API_NAME="${PREFIX}-api"

REGION=$(aws configure get region || echo "us-west-2")

echo "==> API Gateway: $API_NAME"
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" \
  --output text 2>/dev/null || echo "")
if [[ -n "$API_ID" && "$API_ID" != "None" ]]; then
  aws apigatewayv2 delete-api --api-id "$API_ID"
  echo "Deleted API: $API_ID"
fi

echo "==> Lambda: $FUNCTION_NAME"
aws lambda delete-function --function-name "$FUNCTION_NAME" 2>/dev/null || true

echo "==> S3 buckets matching ${PREFIX}-assets-*"
BUCKETS=$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name, '${PREFIX}-assets-')].Name" \
  --output text 2>/dev/null || echo "")
for BUCKET in $BUCKETS; do
  if [[ -n "$BUCKET" && "$BUCKET" != "None" ]]; then
    echo "  Emptying and deleting: $BUCKET"
    aws s3 rm "s3://${BUCKET}" --recursive 2>/dev/null || true
    aws s3api delete-bucket --bucket "$BUCKET" 2>/dev/null || true
  fi
done

echo "==> IAM: $ROLE_NAME"
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${PREFIX}-access" 2>/dev/null || true
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" 2>/dev/null || true

echo "==> DynamoDB: $TABLE_NAME"
aws dynamodb delete-table --table-name "$TABLE_NAME" 2>/dev/null || true

echo "Teardown complete."
