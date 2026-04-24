#!/usr/bin/env zsh
set -euo pipefail

ENVIRONMENT="${1:-dev}"
ROLE_NAME="hello-world-unmanaged-iamrole-${ENVIRONMENT}"
FUNCTION_NAME="hello-world-unmanaged-lambda-${ENVIRONMENT}"
API_NAME="hello-world-unmanaged-api-${ENVIRONMENT}"

# IAM Role
echo "Creating IAM role: $ROLE_NAME"
ROLE_ARN=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

echo "Role ARN: $ROLE_ARN"

# IAM propagation delay
sleep 10

# Package Lambda code
TMP_DIR=$(mktemp -d)
cat > "$TMP_DIR/index.py" <<'PYEOF'
def handler(event, context):
    return {
        "statusCode": 200,
        "body": "Hello, World!"
    }
PYEOF
zip -j "$TMP_DIR/function.zip" "$TMP_DIR/index.py" > /dev/null

# Lambda function
echo "Creating Lambda function: $FUNCTION_NAME"
FUNCTION_ARN=$(aws lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime python3.12 \
  --handler index.handler \
  --role "$ROLE_ARN" \
  --zip-file "fileb://$TMP_DIR/function.zip" \
  --tags "Environment=$ENVIRONMENT" \
  --query FunctionArn --output text)
rm -rf "$TMP_DIR"

echo "Function ARN: $FUNCTION_ARN"
aws lambda wait function-active --function-name "$FUNCTION_NAME"

# API Gateway HTTP API
# Lambda Function URLs with AuthType=NONE are blocked by account-level
# Lambda Block Public Access (RestrictPublicResource). API Gateway uses
# IAM-authenticated Lambda invocations internally, bypassing this restriction.
echo "Creating API Gateway HTTP API: $API_NAME"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region)
API_ID=$(aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --query ApiId --output text)

# Lambda integration (AWS_PROXY passes the full HTTP request to Lambda)
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${FUNCTION_ARN}/invocations" \
  --payload-format-version "2.0" \
  --query IntegrationId --output text)

# Default catch-all route
aws apigatewayv2 create-route \
  --api-id "$API_ID" \
  --route-key "GET /" \
  --target "integrations/${INTEGRATION_ID}" > /dev/null

# Auto-deploy stage
aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy > /dev/null

# Allow API Gateway to invoke the Lambda function
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id AllowAPIGateway \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/" > /dev/null

ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/"

echo ""
echo "Function Name: $FUNCTION_NAME"
echo "API Gateway:   $ENDPOINT"
echo "API ID:        $API_ID"
echo ""

echo "Test with: curl $ENDPOINT"

# curl -s https://6facw878h7.execute-api.us-west-2.amazonaws.com/
