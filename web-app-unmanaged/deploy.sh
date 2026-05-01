#!/usr/bin/env zsh
set -euo pipefail

ENVIRONMENT="${1:-dev}"
PREFIX="web-app-unmanaged-${ENVIRONMENT}"
TABLE_NAME="${PREFIX}-items"
BUCKET_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 8 2>/dev/null || openssl rand -hex 4)
BUCKET_NAME="${PREFIX}-assets-${BUCKET_SUFFIX}"
ROLE_NAME="${PREFIX}-role"
FUNCTION_NAME="${PREFIX}-api"
API_NAME="${PREFIX}-api"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-west-2")

echo "==> DynamoDB table: $TABLE_NAME"
aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions \
      AttributeName=id,AttributeType=S \
      AttributeName=status,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --global-secondary-indexes '[{
    "IndexName": "status-index",
    "KeySchema": [{"AttributeName":"status","KeyType":"HASH"}],
    "Projection": {"ProjectionType":"ALL"}
  }]' \
  --tags Key=Environment,Value="$ENVIRONMENT" \
  > /dev/null

echo "==> S3 bucket: $BUCKET_NAME"
if [[ "$REGION" == "us-east-1" ]]; then
  aws s3api create-bucket --bucket "$BUCKET_NAME" > /dev/null
else
  aws s3api create-bucket --bucket "$BUCKET_NAME" \
    --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
fi
aws s3api put-bucket-cors --bucket "$BUCKET_NAME" --cors-configuration '{
  "CORSRules": [{
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET","PUT"],
    "AllowedOrigins": ["*"],
    "MaxAgeSeconds": 3000
  }]
}'

echo "==> IAM role: $ROLE_NAME"
ROLE_ARN=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{
      "Effect":"Allow",
      "Principal":{"Service":"lambda.amazonaws.com"},
      "Action":"sts:AssumeRole"
    }]
  }' \
  --query Role.Arn --output text)

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${PREFIX}-access" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"dynamodb:GetItem\",\"dynamodb:PutItem\",\"dynamodb:UpdateItem\",
                     \"dynamodb:DeleteItem\",\"dynamodb:Query\",\"dynamodb:Scan\"],
        \"Resource\": [
          \"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}\",
          \"arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}/index/*\"
        ]
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\",\"s3:ListBucket\"],
        \"Resource\": [
          \"arn:aws:s3:::${BUCKET_NAME}\",
          \"arn:aws:s3:::${BUCKET_NAME}/*\"
        ]
      }
    ]
  }"

echo "Waiting for IAM propagation..."
sleep 10

echo "==> Lambda function: $FUNCTION_NAME"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/index.py" <<'PYEOF'
import json, os, uuid, boto3
from datetime import datetime, timezone

TABLE  = os.environ["TABLE_NAME"]
BUCKET = os.environ["BUCKET_NAME"]
dynamo = boto3.resource("dynamodb")
table  = dynamo.Table(TABLE)
s3     = boto3.client("s3")

def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path   = event.get("rawPath", "/")
    parts  = [p for p in path.strip("/").split("/") if p]

    # POST /items
    if method == "POST" and parts == ["items"]:
        body = json.loads(event.get("body") or "{}")
        item = {
            "id":        str(uuid.uuid4()),
            "status":    body.get("status", "active"),
            "title":     body.get("title", "untitled"),
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }
        table.put_item(Item=item)
        return resp(201, item)

    # GET /items
    if method == "GET" and parts == ["items"]:
        status = (event.get("queryStringParameters") or {}).get("status")
        if status:
            result = table.query(
                IndexName="status-index",
                KeyConditionExpression="#s = :s",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": status},
            )
        else:
            result = table.scan()
        return resp(200, result["Items"])

    # GET /items/{id}
    if method == "GET" and len(parts) == 2 and parts[0] == "items":
        r = table.get_item(Key={"id": parts[1]})
        item = r.get("Item")
        return resp(200, item) if item else resp(404, {"error": "not found"})

    # DELETE /items/{id}
    if method == "DELETE" and len(parts) == 2 and parts[0] == "items":
        table.delete_item(Key={"id": parts[1]})
        return resp(204, None)

    # GET /upload-url?key=...
    if method == "GET" and parts == ["upload-url"]:
        key = (event.get("queryStringParameters") or {}).get("key", "upload.bin")
        url = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": BUCKET, "Key": key},
            ExpiresIn=3600,
        )
        return resp(200, {"url": url, "key": key})

    return resp(404, {"error": "not found"})

def resp(code, body):
    return {
        "statusCode": code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body) if body is not None else "",
    }
PYEOF

(cd "$TMP_DIR" && zip -q function.zip index.py)

FUNCTION_ARN=$(aws lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime python3.12 \
  --handler index.handler \
  --role "$ROLE_ARN" \
  --zip-file "fileb://$TMP_DIR/function.zip" \
  --timeout 30 \
  --environment "Variables={TABLE_NAME=${TABLE_NAME},BUCKET_NAME=${BUCKET_NAME}}" \
  --tags "Environment=$ENVIRONMENT" \
  --query FunctionArn --output text)

aws lambda wait function-active --function-name "$FUNCTION_NAME"
echo "Function ARN: $FUNCTION_ARN"

echo "==> API Gateway: $API_NAME"
API_ID=$(aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --query ApiId --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${FUNCTION_ARN}/invocations" \
  --payload-format-version "2.0" \
  --query IntegrationId --output text)

for ROUTE in "GET /items" "POST /items" "GET /items/{id}" "DELETE /items/{id}" "GET /upload-url"; do
  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "$ROUTE" \
    --target "integrations/${INTEGRATION_ID}" > /dev/null
done

aws apigatewayv2 create-stage \
  --api-id "$API_ID" \
  --stage-name '$default' \
  --auto-deploy > /dev/null

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id AllowAPIGateway \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" > /dev/null

ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Environment  : $ENVIRONMENT"
echo "  DynamoDB     : $TABLE_NAME"
echo "  S3 bucket    : $BUCKET_NAME"
echo "  Lambda       : $FUNCTION_NAME"
echo "  API endpoint : $ENDPOINT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Example commands:"
echo ""
echo "  # Create an item"
echo "  curl -s -X POST $ENDPOINT/items \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"title\":\"Test item\",\"status\":\"active\"}' | python3 -m json.tool"
echo ""
echo "  # List all items"
echo "  curl -s $ENDPOINT/items | python3 -m json.tool"
echo ""
echo "  # List by status"
echo "  curl -s '$ENDPOINT/items?status=active' | python3 -m json.tool"
echo ""
echo "  # Get a presigned upload URL"
echo "  curl -s '$ENDPOINT/upload-url?key=photo.png' | python3 -m json.tool"
