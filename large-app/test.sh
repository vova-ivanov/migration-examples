#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${STACK_NAME:-large-app}"
ENV="${ENV:-dev}"
REGION="${AWS_REGION:-us-west-2}"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    pass "$label"
  else
    fail "$label"
  fi
}

echo "=== Large App Sanity Check ==="
echo "Stack:  $STACK_NAME"
echo "Env:    $ENV"
echo "Region: $REGION"
echo ""

# ── CloudFormation stack ──────────────────────────────────────────────────────
echo "--- CloudFormation ---"
STATUS=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].StackStatus" \
  --output text 2>/dev/null || echo "MISSING")

if [[ "$STATUS" == "CREATE_COMPLETE" || "$STATUS" == "UPDATE_COMPLETE" ]]; then
  pass "Stack status: $STATUS"
else
  fail "Stack status: $STATUS (expected CREATE_COMPLETE or UPDATE_COMPLETE)"
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")

# ── Lambda functions ──────────────────────────────────────────────────────────
echo ""
echo "--- Lambda functions ---"
for FN in api-handler auth-handler worker notifier scheduler cleanup; do
  NAME="app-${FN}-${ENV}"
  STATE=$(aws lambda get-function-configuration \
    --function-name "$NAME" \
    --region "$REGION" \
    --query "State" \
    --output text 2>/dev/null || echo "MISSING")
  if [[ "$STATE" == "Active" ]]; then
    pass "$NAME  (State=Active)"
  else
    fail "$NAME  (State=$STATE)"
  fi
done

# Invoke api-handler and auth-handler with a minimal payload to confirm they respond
echo ""
echo "--- Lambda invocations ---"
for FN in api-handler auth-handler; do
  NAME="app-${FN}-${ENV}"
  SC=$(aws lambda invoke \
    --function-name "$NAME" \
    --region "$REGION" \
    --payload '{"httpMethod":"GET","path":"/health","pathParameters":{}}' \
    --cli-binary-format raw-in-base64-out \
    /tmp/lambda_out_${FN}.json \
    --query "StatusCode" \
    --output text 2>/dev/null || echo "0")
  if [[ "$SC" == "200" ]]; then
    pass "$NAME  invoke returned HTTP $SC"
  else
    fail "$NAME  invoke returned HTTP $SC"
  fi
done

# ── DynamoDB tables ───────────────────────────────────────────────────────────
echo ""
echo "--- DynamoDB tables ---"
for TBL in items orders sessions users; do
  NAME="app-${TBL}-${ENV}"
  TBL_STATUS=$(aws dynamodb describe-table \
    --table-name "$NAME" \
    --region "$REGION" \
    --query "Table.TableStatus" \
    --output text 2>/dev/null || echo "MISSING")
  if [[ "$TBL_STATUS" == "ACTIVE" ]]; then
    pass "$NAME  (ACTIVE)"
  else
    fail "$NAME  ($TBL_STATUS)"
  fi
done

# ── SQS queues ────────────────────────────────────────────────────────────────
echo ""
echo "--- SQS queues ---"
for Q in jobs notifications jobs-dlq notifications-dlq; do
  NAME="app-${Q}-${ENV}"
  check "$NAME exists" \
    aws sqs get-queue-url \
      --queue-name "$NAME" \
      --region "$REGION"
done

# ── SNS topics ────────────────────────────────────────────────────────────────
echo ""
echo "--- SNS topics ---"
for TOPIC in notifications alarms; do
  NAME="app-${TOPIC}-${ENV}"
  check "$NAME exists" \
    aws sns get-topic-attributes \
      --topic-arn "arn:aws:sns:${REGION}:${ACCOUNT_ID}:${NAME}" \
      --region "$REGION"
done

# ── API Gateway ───────────────────────────────────────────────────────────────
echo ""
echo "--- API Gateway ---"
API_ID=$(aws apigateway get-rest-apis \
  --region "$REGION" \
  --query "items[?name=='app-api-${ENV}'].id | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "$API_ID" != "None" && -n "$API_ID" ]]; then
  pass "REST API app-api-${ENV}  (id=$API_ID)"

  STAGE_STATUS=$(aws apigateway get-stage \
    --rest-api-id "$API_ID" \
    --stage-name "$ENV" \
    --region "$REGION" \
    --query "stageName" \
    --output text 2>/dev/null || echo "MISSING")
  if [[ "$STAGE_STATUS" == "$ENV" ]]; then
    pass "Stage '$ENV' deployed"
  else
    fail "Stage '$ENV' not found"
  fi
else
  fail "REST API app-api-${ENV} not found"
  fail "Stage '$ENV' (skipped — API not found)"
fi

# ── S3 buckets ────────────────────────────────────────────────────────────────
echo ""
echo "--- S3 buckets ---"
for BUCKET_SUFFIX in assets logs backups artifacts; do
  NAME="app-${BUCKET_SUFFIX}-${ENV}-${ACCOUNT_ID}"
  check "$NAME exists" \
    aws s3api head-bucket \
      --bucket "$NAME" \
      --region "$REGION"
done

# ── Step Functions ────────────────────────────────────────────────────────────
echo ""
echo "--- Step Functions ---"
SF_NAME="app-batch-${ENV}"
SF_STATUS=$(aws stepfunctions describe-state-machine \
  --state-machine-arn "arn:aws:states:${REGION}:${ACCOUNT_ID}:stateMachine:${SF_NAME}" \
  --region "$REGION" \
  --query "status" \
  --output text 2>/dev/null || echo "MISSING")
if [[ "$SF_STATUS" == "ACTIVE" ]]; then
  pass "$SF_NAME  (ACTIVE)"
else
  fail "$SF_NAME  ($SF_STATUS)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "================================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS/$TOTAL passed"
if [[ $FAIL -gt 0 ]]; then
  echo "$FAIL check(s) FAILED"
  exit 1
else
  echo "All checks passed."
fi
