#!/usr/bin/env zsh
set -euo pipefail

ENVIRONMENT="${1:-dev}"
STACK_NAME="mixed-unmanaged-infra-${ENVIRONMENT}"
PREFIX="mixed-unmanaged-${ENVIRONMENT}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(aws configure get region || echo "us-west-2")

# ── Phase 1: CloudFormation stack (infra layer) ────────────────────────────────
echo "==> Deploying CloudFormation stack: $STACK_NAME"
aws cloudformation deploy \
  --template-file infra.yaml \
  --stack-name "$STACK_NAME" \
  --parameter-overrides Environment="$ENVIRONMENT" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset

# Read outputs from the stack
TABLE_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='OrdersTableName'].OutputValue" \
  --output text)

BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='AssetsBucketName'].OutputValue" \
  --output text)

QUEUE_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='OrderQueueUrl'].OutputValue" \
  --output text)

QUEUE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='OrderQueueArn'].OutputValue" \
  --output text)

echo "Stack outputs:"
echo "  Table  : $TABLE_NAME"
echo "  Bucket : $BUCKET_NAME"
echo "  Queue  : $QUEUE_URL"

# ── Phase 2: Manually created Lambda functions (application layer) ─────────────
# These are NOT part of the CloudFormation stack. They are added via the CLI
# after the infra is in place, just as a developer might do during rapid
# iteration or to work around a deployment process that only manages infra.

ROLE_NAME="${PREFIX}-lambda-role"
API_FUNCTION="${PREFIX}-api"
WORKER_FUNCTION="${PREFIX}-worker"
API_NAME="${PREFIX}-api"

echo ""
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

# Grant access to the CloudFormation-managed resources
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "${PREFIX}-resource-access" \
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
      },
      {
        \"Effect\": \"Allow\",
        \"Action\": [\"sqs:SendMessage\",\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",
                     \"sqs:GetQueueAttributes\"],
        \"Resource\": \"${QUEUE_ARN}\"
      }
    ]
  }"

echo "Waiting for IAM propagation..."
sleep 10

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── API Lambda ─────────────────────────────────────────────────────────────────
echo "==> Lambda function: $API_FUNCTION"
cat > "$TMP_DIR/api.py" <<'PYEOF'
import json, os, uuid, boto3
from datetime import datetime, timezone

TABLE     = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]
dynamo    = boto3.resource("dynamodb")
table     = dynamo.Table(TABLE)
sqs       = boto3.client("sqs")

def handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path   = event.get("rawPath", "/")
    parts  = [p for p in path.strip("/").split("/") if p]

    if method == "POST" and parts == ["orders"]:
        body  = json.loads(event.get("body") or "{}")
        order = {
            "orderId":   str(uuid.uuid4()),
            "status":    "pending",
            "item":      body.get("item", "unknown"),
            "quantity":  body.get("quantity", 1),
            "createdAt": datetime.now(timezone.utc).isoformat(),
        }
        table.put_item(Item=order)
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(order))
        return resp(201, order)

    if method == "GET" and parts == ["orders"]:
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

    if method == "GET" and len(parts) == 2 and parts[0] == "orders":
        r = table.get_item(Key={"orderId": parts[1]})
        item = r.get("Item")
        return resp(200, item) if item else resp(404, {"error": "not found"})

    return resp(404, {"error": "not found"})

def resp(code, body):
    return {"statusCode": code, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(body)}
PYEOF
cp "$TMP_DIR/api.py" "$TMP_DIR/index.py"
(cd "$TMP_DIR" && zip -q api.zip index.py)

API_FUNCTION_ARN=$(aws lambda create-function \
  --function-name "$API_FUNCTION" \
  --runtime python3.12 \
  --handler index.handler \
  --role "$ROLE_ARN" \
  --zip-file "fileb://$TMP_DIR/api.zip" \
  --timeout 30 \
  --environment "Variables={TABLE_NAME=${TABLE_NAME},QUEUE_URL=${QUEUE_URL}}" \
  --tags "Environment=$ENVIRONMENT,Stack=none,Layer=application" \
  --query FunctionArn --output text)

aws lambda wait function-active --function-name "$API_FUNCTION"

# ── Worker Lambda ──────────────────────────────────────────────────────────────
echo "==> Lambda function: $WORKER_FUNCTION"
cat > "$TMP_DIR/worker.py" <<'PYEOF'
import json, os, boto3

TABLE  = os.environ["TABLE_NAME"]
BUCKET = os.environ["BUCKET_NAME"]
dynamo = boto3.resource("dynamodb")
table  = dynamo.Table(TABLE)
s3     = boto3.client("s3")

def handler(event, context):
    for record in event.get("Records", []):
        order = json.loads(record["body"])
        order_id = order["orderId"]
        table.update_item(
            Key={"orderId": order_id},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "processed"},
        )
        s3.put_object(
            Bucket=BUCKET,
            Key=f"receipts/{order_id}.json",
            Body=json.dumps(order),
        )
    return {"batchItemFailures": []}
PYEOF
cp "$TMP_DIR/worker.py" "$TMP_DIR/index.py"
(cd "$TMP_DIR" && zip -q worker.zip index.py)

WORKER_FUNCTION_ARN=$(aws lambda create-function \
  --function-name "$WORKER_FUNCTION" \
  --runtime python3.12 \
  --handler index.handler \
  --role "$ROLE_ARN" \
  --zip-file "fileb://$TMP_DIR/worker.zip" \
  --timeout 60 \
  --environment "Variables={TABLE_NAME=${TABLE_NAME},BUCKET_NAME=${BUCKET_NAME}}" \
  --tags "Environment=$ENVIRONMENT,Stack=none,Layer=application" \
  --query FunctionArn --output text)

aws lambda wait function-active --function-name "$WORKER_FUNCTION"

# Wire SQS → Worker via event source mapping
aws lambda create-event-source-mapping \
  --function-name "$WORKER_FUNCTION" \
  --event-source-arn "$QUEUE_ARN" \
  --batch-size 5 \
  --enabled > /dev/null

# ── API Gateway ────────────────────────────────────────────────────────────────
echo "==> API Gateway: $API_NAME"
API_ID=$(aws apigatewayv2 create-api \
  --name "$API_NAME" \
  --protocol-type HTTP \
  --query ApiId --output text)

INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id "$API_ID" \
  --integration-type AWS_PROXY \
  --integration-uri "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${API_FUNCTION_ARN}/invocations" \
  --payload-format-version "2.0" \
  --query IntegrationId --output text)

for ROUTE in "GET /orders" "POST /orders" "GET /orders/{orderId}"; do
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
  --function-name "$API_FUNCTION" \
  --statement-id AllowAPIGateway \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" > /dev/null

ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CloudFormation stack : $STACK_NAME"
echo "  DynamoDB table       : $TABLE_NAME   (CFN-managed)"
echo "  S3 bucket            : $BUCKET_NAME  (CFN-managed)"
echo "  SQS queue            : $QUEUE_URL    (CFN-managed)"
echo "  API Lambda           : $API_FUNCTION  (unmanaged)"
echo "  Worker Lambda        : $WORKER_FUNCTION (unmanaged)"
echo "  API endpoint         : $ENDPOINT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Example commands:"
echo ""
echo "  # Create an order (publishes to SQS, worker picks it up asynchronously)"
echo "  curl -s -X POST $ENDPOINT/orders \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"item\":\"widget\",\"quantity\":3}' | python3 -m json.tool"
echo ""
echo "  # List orders"
echo "  curl -s $ENDPOINT/orders | python3 -m json.tool"
echo ""
echo "  # List by status"
echo "  curl -s '$ENDPOINT/orders?status=processed' | python3 -m json.tool"
