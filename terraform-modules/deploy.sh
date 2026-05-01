#!/usr/bin/env zsh
set -euo pipefail

# Build a minimal lambda.zip if one does not already exist
if [[ ! -f lambda.zip ]]; then
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  cat > "$TMP_DIR/index.py" <<'PYEOF'
import json, os, boto3

def handler(event, context):
    role = os.environ.get("ROLE", "unknown")
    bucket = os.environ.get("BUCKET", "")
    s3 = boto3.client("s3")
    key = f"{role}/last-invocation.json"
    payload = {"role": role, "event": event}
    s3.put_object(Bucket=bucket, Key=key, Body=json.dumps(payload))
    return {"statusCode": 200, "body": json.dumps({"role": role, "wrote": key})}
PYEOF
  (cd "$TMP_DIR" && zip -q function.zip index.py)
  cp "$TMP_DIR/function.zip" lambda.zip
fi

terraform init -upgrade
terraform apply -auto-approve

echo ""
echo "Outputs:"
terraform output
