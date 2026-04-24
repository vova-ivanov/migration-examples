#!/usr/bin/env zsh
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./deploy.sh [environment] [deploy-bucket]
#
#   environment   dev | staging | prod          (default: dev)
#   deploy-bucket S3 bucket for packaged templates (default: auto-derived)
#
# ── Examples ──────────────────────────────────────────────────────────────────
#
#   ./deploy.sh
#   ./deploy.sh staging
#   ./deploy.sh prod my-cfn-artifacts-bucket
#
# ─────────────────────────────────────────────────────────────────────────────

ENVIRONMENT="${1:-dev}"
STACK_NAME="${STACK_NAME:-cloudformation-complex-app-${ENVIRONMENT}}"
PACKAGED_TEMPLATE="$(mktemp /tmp/cfn-packaged-XXXXXX.yaml)"
trap 'rm -f "$PACKAGED_TEMPLATE"' EXIT

# ── Resolve deploy bucket ─────────────────────────────────────────────────────

if [[ -n "${2:-}" ]]; then
  DEPLOY_BUCKET="$2"
else
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  # Prefer environment variables over the config file for region
  REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  REGION="${REGION:-us-east-1}"
  DEPLOY_BUCKET="cfn-deploy-${ACCOUNT_ID}-${REGION}"
fi

# Create the deploy bucket if it does not exist
if ! aws s3api head-bucket --bucket "$DEPLOY_BUCKET" 2>/dev/null; then
  echo "Creating deploy bucket: $DEPLOY_BUCKET"
  REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}}"
  REGION="${REGION:-us-east-1}"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$DEPLOY_BUCKET"
  else
    aws s3api create-bucket --bucket "$DEPLOY_BUCKET" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
  aws s3api put-bucket-versioning --bucket "$DEPLOY_BUCKET" \
    --versioning-configuration Status=Enabled
fi

# ── Package — upload nested templates and rewrite TemplateURLs ───────────────
# aws cloudformation package scans for AWS::CloudFormation::Stack resources
# with local TemplateURL paths, uploads each file to S3, and outputs a new
# template with the S3 URLs already substituted in.

echo "Packaging templates → s3://${DEPLOY_BUCKET}/complex-app/"
aws cloudformation package \
  --template-file main.yaml \
  --s3-bucket "$DEPLOY_BUCKET" \
  --s3-prefix "complex-app" \
  --output-template-file "$PACKAGED_TEMPLATE"

# ── Load environment parameters ──────────────────────────────────────────────

PARAMS_FILE="parameters/${ENVIRONMENT}.json"
if [[ ! -f "$PARAMS_FILE" ]]; then
  echo "Error: parameter file '${PARAMS_FILE}' not found." >&2
  exit 1
fi

# Build a parameter array — one element per Key=Value pair.
# Uses a single-quoted heredoc so the shell never touches the Python code.
# Each element is kept as its own array entry so quoting is exact.
typeset -a PARAM_OVERRIDES
while IFS= read -r line; do
  [[ -n "$line" ]] && PARAM_OVERRIDES+=("$line")
done < <(python3 -c '
import json, sys
for p in json.load(open(sys.argv[1])):
    print("{}={}".format(p["ParameterKey"], p["ParameterValue"]))
' "$PARAMS_FILE")

# ── Deploy ────────────────────────────────────────────────────────────────────

echo "Deploying stack: ${STACK_NAME}  (environment: ${ENVIRONMENT})"
aws cloudformation deploy \
  --template-file "$PACKAGED_TEMPLATE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides "${PARAM_OVERRIDES[@]}" \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --tags Environment="$ENVIRONMENT" StackFamily=complex-app \
  --no-fail-on-empty-changeset

# ── Print outputs ─────────────────────────────────────────────────────────────

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[*].[OutputKey,OutputValue]" \
  --output table

API_URL=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiEndpoint'].OutputValue" \
  --output text 2>/dev/null || true)

if [[ -n "$API_URL" && "$API_URL" != "None" ]]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  API endpoint : $API_URL"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "  Example commands  (set TOKEN after login):"
  echo ""
  echo "  # Register a new user"
  echo "  APP_CLIENT_ID=\$(aws cloudformation describe-stacks \\"
  echo "    --stack-name ${STACK_NAME} \\"
  echo "    --query \"Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue\" \\"
  echo "    --output text)"
  echo "  aws cognito-idp sign-up \\"
  echo "    --client-id \$APP_CLIENT_ID \\"
  echo "    --username user@example.com \\"
  echo "    --password 'P@ssw0rd!' \\"
  echo "    --user-attributes Name=email,Value=user@example.com"
  echo ""
  echo "  # Confirm sign-up (code arrives by email)"
  echo "  aws cognito-idp confirm-sign-up \\"
  echo "    --client-id \$APP_CLIENT_ID \\"
  echo "    --username user@example.com \\"
  echo "    --confirmation-code 123456"
  echo ""
  echo "  # Log in → capture access token"
  echo "  TOKEN=\$(curl -s -X POST ${API_URL}/auth/login \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"email\":\"user@example.com\",\"password\":\"P@ssw0rd!\"}' \\"
  echo "    | python3 -c \"import sys,json; print(json.load(sys.stdin)['accessToken'])\")"
  echo ""
  echo "  # Create an item"
  echo "  curl -s -X POST ${API_URL}/items \\"
  echo "    -H \"Authorization: Bearer \$TOKEN\" \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"title\":\"My First Item\",\"ownerId\":\"user-123\"}' | python3 -m json.tool"
  echo ""
  echo "  # List items"
  echo "  curl -s ${API_URL}/items -H \"Authorization: Bearer \$TOKEN\" | python3 -m json.tool"
  echo ""
  echo "  # List by status"
  echo "  curl -s '${API_URL}/items?status=active' -H \"Authorization: Bearer \$TOKEN\" | python3 -m json.tool"
  echo ""
  echo "  # Get / update / delete one item  (set ITEM_ID first)"
  echo "  curl -s ${API_URL}/items/\$ITEM_ID -H \"Authorization: Bearer \$TOKEN\" | python3 -m json.tool"
  echo "  curl -s -X PUT ${API_URL}/items/\$ITEM_ID \\"
  echo "    -H \"Authorization: Bearer \$TOKEN\" \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"status\":\"active\",\"title\":\"Updated\"}' | python3 -m json.tool"
  echo "  curl -s -X DELETE ${API_URL}/items/\$ITEM_ID -H \"Authorization: Bearer \$TOKEN\" | python3 -m json.tool"
  echo ""
  echo "  # Get a presigned upload URL"
  echo "  curl -s -X POST ${API_URL}/assets/upload-url \\"
  echo "    -H \"Authorization: Bearer \$TOKEN\" \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"key\":\"items/photo.png\",\"contentType\":\"image/png\"}' | python3 -m json.tool"
  echo ""
  echo "  # Get current user"
  echo "  curl -s ${API_URL}/auth/me -H \"Authorization: Bearer \$TOKEN\" | python3 -m json.tool"
  echo ""
  echo "  # Refresh token"
  echo "  curl -s -X POST ${API_URL}/auth/refresh \\"
  echo "    -H 'Content-Type: application/json' \\"
  echo "    -d '{\"refreshToken\":\"\$REFRESH_TOKEN\"}' | python3 -m json.tool"
  echo ""
  echo "  # Start a Step Functions batch workflow"
  echo "  SM_ARN=\$(aws stepfunctions list-state-machines \\"
  echo "    --query \"stateMachines[?name=='app-batch-processor-${ENVIRONMENT}'].stateMachineArn\" \\"
  echo "    --output text)"
  echo "  aws stepfunctions start-execution \\"
  echo "    --state-machine-arn \$SM_ARN \\"
  echo "    --input '{\"processingType\":\"bulk\",\"items\":[{\"itemId\":\"1\"},{\"itemId\":\"2\"}]}'"
fi
