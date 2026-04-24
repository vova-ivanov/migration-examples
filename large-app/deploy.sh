#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="${STACK_NAME:-large-app}"
ENV="${ENV:-dev}"
REGION="${AWS_REGION:-us-west-2}"
TEMPLATE_FILE="large-app.yaml"
PARAMS_FILE="parameters/${ENV}.json"

echo "=== Large App CloudFormation Deploy ==="
echo "Stack:  $STACK_NAME"
echo "Env:    $ENV"
echo "Region: $REGION"
echo ""

# Step 1: Build the merged template
echo "--- Building template ---"
python3 build.py
echo ""

# Step 2: Upload to S3 and validate
# The template is >51,200 bytes so validate-template requires an S3 URL.
echo "--- Uploading template to S3 for validation ---"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
DEPLOY_BUCKET="cfn-deploy-${ACCOUNT_ID}-${REGION}"

if ! aws s3api head-bucket --bucket "$DEPLOY_BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Creating deploy bucket: $DEPLOY_BUCKET"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$DEPLOY_BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$DEPLOY_BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

S3_KEY="large-app/${ENV}/template-$(date +%s).yaml"
aws s3 cp "$TEMPLATE_FILE" "s3://${DEPLOY_BUCKET}/${S3_KEY}" --region "$REGION"
TEMPLATE_URL="https://${DEPLOY_BUCKET}.s3.${REGION}.amazonaws.com/${S3_KEY}"

echo "--- Validating template ---"
aws cloudformation validate-template \
  --template-url "$TEMPLATE_URL" \
  --region "$REGION" \
  --output text
echo ""

# Step 3: Convert parameters from ParameterKey/ParameterValue JSON to Key=Value pairs
typeset -a PARAM_OVERRIDES
while IFS= read -r line; do
  [[ -n "$line" ]] && PARAM_OVERRIDES+=("$line")
done < <(python3 -c '
import json, sys
for p in json.load(open(sys.argv[1])):
    v = p["ParameterValue"]
    if v != "":
        print("{}={}".format(p["ParameterKey"], v))
' "$PARAMS_FILE")

# Step 3b: Create and upload the Lambda layer zip if it doesn't already exist in S3
LAYER_KEY="large-app/layers/utils.zip"
if ! aws s3api head-object --bucket "$DEPLOY_BUCKET" --key "$LAYER_KEY" --region "$REGION" 2>/dev/null; then
  echo "--- Creating layer zip ---"
  LAYER_TMP=$(mktemp -d)
  mkdir -p "$LAYER_TMP/python"
  cat > "$LAYER_TMP/python/utils.py" << 'PYEOF'
"""Shared utilities layer."""
import json, os, logging

logger = logging.getLogger()
logger.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

def ok(body, status=200):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(body, default=str)}

def err(status, msg):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps({"error": msg})}
PYEOF
  (cd "$LAYER_TMP" && zip -qr utils.zip python/)
  aws s3 cp "$LAYER_TMP/utils.zip" "s3://${DEPLOY_BUCKET}/${LAYER_KEY}" --region "$REGION"
  rm -rf "$LAYER_TMP"
  echo "Layer zip uploaded to s3://${DEPLOY_BUCKET}/${LAYER_KEY}"
fi

# Step 4: Deploy — pass --s3-bucket so the CLI uploads the oversized template before deploying
echo "--- Deploying stack ---"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --parameter-overrides "${PARAM_OVERRIDES[@]}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --s3-bucket "$DEPLOY_BUCKET" \
  --s3-prefix "large-app/${ENV}" \
  --region "$REGION" \
  --no-fail-on-empty-changeset

echo ""
echo "--- Stack outputs ---"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table
