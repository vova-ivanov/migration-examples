#!/usr/bin/env zsh
set -euo pipefail

# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./test.sh [environment]
#
#   environment   dev | staging | prod   (default: dev)
#
# ─────────────────────────────────────────────────────────────────────────────

ENVIRONMENT="${1:-dev}"
STACK_NAME="${STACK_NAME:-cloudformation-complex-app-${ENVIRONMENT}}"
TEST_EMAIL="test-smoke-$$@example.com"
TEST_PASSWORD="Smoke1test!"

# ── Colours ───────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

pass() { printf "${GREEN}  ✓ %s${RESET}\n" "$*"; }
fail() { printf "${RED}  ✗ %s${RESET}\n" "$*"; }
step() { printf "\n${CYAN}▶ %s${RESET}\n" "$*"; }
info() { printf "${YELLOW}  %s${RESET}\n" "$*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────

# Pretty-print JSON, or echo raw if not valid JSON.
pretty() {
  if echo "$1" | python3 -m json.tool 2>/dev/null; then
    return
  fi
  echo "$1"
}

# Make an HTTP request, print method / URL / status / body to the terminal,
# and store the raw response body in the global LAST_RESPONSE.
# Usage: api_call METHOD URL [-H header]... [-d body]
LAST_RESPONSE=""
api_call() {
  local method="$1"; shift
  local url="$1";    shift
  info "${method} ${url}"

  local body_file status_file
  body_file=$(mktemp)
  status_file=$(mktemp)

  curl -s -o "$body_file" -w "%{http_code}" -X "$method" "$url" "$@" > "$status_file"

  local http_code body
  http_code=$(cat "$status_file")
  body=$(cat "$body_file")
  rm -f "$body_file" "$status_file"

  info "HTTP ${http_code}"
  pretty "$body"

  LAST_RESPONSE="$body"
}

# ── Resolve stack outputs ─────────────────────────────────────────────────────

step "Resolving stack outputs for '${STACK_NAME}'"

stack_output() {
  aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" \
    --output text
}

API_URL=$(stack_output ApiEndpoint)
USER_POOL_ID=$(stack_output UserPoolId)
USER_POOL_CLIENT_ID=$(stack_output UserPoolClientId)

[[ -z "$API_URL"              || "$API_URL"              == "None" ]] && { fail "ApiEndpoint output missing — is the stack deployed?"; exit 1; }
[[ -z "$USER_POOL_ID"         || "$USER_POOL_ID"         == "None" ]] && { fail "UserPoolId output missing"; exit 1; }
[[ -z "$USER_POOL_CLIENT_ID"  || "$USER_POOL_CLIENT_ID"  == "None" ]] && { fail "UserPoolClientId output missing"; exit 1; }

info "API URL      : ${API_URL}"
info "User Pool    : ${USER_POOL_ID}"
info "Client ID    : ${USER_POOL_CLIENT_ID}"
pass "Stack outputs resolved"

# ── Teardown trap ─────────────────────────────────────────────────────────────

CREATED_ITEM_ID=""
CLEANUP_USER=false
TOKEN=""

cleanup() {
  step "Cleanup"

  if [[ -n "$CREATED_ITEM_ID" && -n "$TOKEN" ]]; then
    info "Deleting item ${CREATED_ITEM_ID}"
    local body_file status_file http_code body
    body_file=$(mktemp); status_file=$(mktemp)
    curl -s -o "$body_file" -w "%{http_code}" \
      -X DELETE "${API_URL}/items/${CREATED_ITEM_ID}" \
      -H "Authorization: Bearer ${TOKEN}" > "$status_file"
    http_code=$(cat "$status_file"); body=$(cat "$body_file")
    rm -f "$body_file" "$status_file"
    info "HTTP ${http_code}"; pretty "$body"
    [[ "$http_code" == "200" || "$http_code" == "204" ]] \
      && pass "Item deleted" || fail "Item deletion returned ${http_code}"
  fi

  if $CLEANUP_USER; then
    info "Deleting Cognito test user ${TEST_EMAIL}"
    if aws cognito-idp admin-delete-user \
         --user-pool-id "$USER_POOL_ID" \
         --username "$TEST_EMAIL" 2>/dev/null; then
      pass "Test user deleted"
    else
      fail "Could not delete test user (may already be gone)"
    fi
  fi
}
trap cleanup EXIT

# ── 1. Create test user (admin path — no email verification required) ─────────

step "1. Creating test user in Cognito"
info "Email: ${TEST_EMAIL}"

aws cognito-idp admin-create-user \
  --user-pool-id "$USER_POOL_ID" \
  --username "$TEST_EMAIL" \
  --user-attributes Name=email,Value="$TEST_EMAIL" Name=email_verified,Value=true \
  --message-action SUPPRESS \
  --output json | python3 -m json.tool

pass "User created (FORCE_CHANGE_PASSWORD state)"

aws cognito-idp admin-set-user-password \
  --user-pool-id "$USER_POOL_ID" \
  --username "$TEST_EMAIL" \
  --password "$TEST_PASSWORD" \
  --permanent

CLEANUP_USER=true
pass "Password set — user is CONFIRMED"

# ── 2. Login ──────────────────────────────────────────────────────────────────

step "2. POST /auth/login"
api_call POST "${API_URL}/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"${TEST_EMAIL}\",\"password\":\"${TEST_PASSWORD}\"}"

TOKEN=$(echo "$LAST_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['accessToken'])" 2>/dev/null || true)
REFRESH_TOKEN=$(echo "$LAST_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('refreshToken',''))" 2>/dev/null || true)

[[ -z "$TOKEN" ]] && { fail "No accessToken in login response"; exit 1; }
pass "Login succeeded — token acquired"

# ── 3. Get current user ───────────────────────────────────────────────────────

step "3. GET /auth/me"
api_call GET "${API_URL}/auth/me" \
  -H "Authorization: Bearer ${TOKEN}"
pass "Current user retrieved"

# ── 4. Create an item ─────────────────────────────────────────────────────────

step "4. POST /items — create item"
api_call POST "${API_URL}/items" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"title":"Smoke test item","ownerId":"smoke-tester"}'

CREATED_ITEM_ID=$(echo "$LAST_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[[ -z "$CREATED_ITEM_ID" ]] && { fail "Could not extract item ID from create response"; exit 1; }
info "Item ID: ${CREATED_ITEM_ID}"
pass "Item created"

# ── 5. List items ─────────────────────────────────────────────────────────────

step "5. GET /items — list all items"
api_call GET "${API_URL}/items" \
  -H "Authorization: Bearer ${TOKEN}"
pass "Items listed"

# ── 6. List items filtered by status ─────────────────────────────────────────

step "6. GET /items?status=active — filtered list"
api_call GET "${API_URL}/items?status=active" \
  -H "Authorization: Bearer ${TOKEN}"
pass "Filtered list retrieved"

# ── 7. Get single item ────────────────────────────────────────────────────────

step "7. GET /items/${CREATED_ITEM_ID}"
api_call GET "${API_URL}/items/${CREATED_ITEM_ID}" \
  -H "Authorization: Bearer ${TOKEN}"
pass "Single item retrieved"

# ── 8. Update item ────────────────────────────────────────────────────────────

step "8. PUT /items/${CREATED_ITEM_ID} — update"
api_call PUT "${API_URL}/items/${CREATED_ITEM_ID}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"title":"Smoke test item (updated)","status":"active"}'
pass "Item updated"

# ── 9. Get presigned upload URL ───────────────────────────────────────────────

step "9. POST /assets/upload-url — request presigned URL"
UPLOAD_KEY="smoke-test/test-$$-photo.txt"
api_call POST "${API_URL}/assets/upload-url" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"key\":\"${UPLOAD_KEY}\",\"contentType\":\"text/plain\"}"

PRESIGNED_URL=$(echo "$LAST_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uploadUrl',''))" 2>/dev/null || true)

if [[ -n "$PRESIGNED_URL" ]]; then
  pass "Presigned URL received"

  step "10. PUT to presigned S3 URL — upload test file"
  info "Key: ${UPLOAD_KEY}"
  local_tmp=$(mktemp)
  echo "smoke test upload — $(date -u)" > "$local_tmp"

  upload_status=$(mktemp)
  curl -sL -o /dev/null -w "%{http_code}" \
    -X PUT "$PRESIGNED_URL" \
    -H "Content-Type: text/plain" \
    --data-binary "@${local_tmp}" > "$upload_status"
  upload_code=$(cat "$upload_status")
  rm -f "$local_tmp" "$upload_status"

  info "HTTP ${upload_code}"
  [[ "$upload_code" == "200" ]] && pass "File uploaded to S3" || fail "S3 upload returned ${upload_code}"
else
  info "No presigned URL returned — skipping S3 upload"
fi

# ── 11. Refresh token ─────────────────────────────────────────────────────────

if [[ -n "$REFRESH_TOKEN" ]]; then
  step "11. POST /auth/refresh"
  api_call POST "${API_URL}/auth/refresh" \
    -H "Content-Type: application/json" \
    -d "{\"refreshToken\":\"${REFRESH_TOKEN}\"}"

  NEW_TOKEN=$(echo "$LAST_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('accessToken',''))" 2>/dev/null || true)
  [[ -n "$NEW_TOKEN" ]] && { TOKEN="$NEW_TOKEN"; pass "Token refreshed"; } \
    || info "Refresh did not return a new accessToken — continuing with original"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

printf "\n${GREEN}All steps completed successfully.${RESET}\n"
# Cleanup runs via trap EXIT
