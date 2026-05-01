#!/usr/bin/env zsh
set -euo pipefail

# Build a minimal lambda.zip if one does not already exist
if [[ ! -f lambda.zip ]]; then
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  cat > "$TMP_DIR/index.py" <<'PYEOF'
import json, os, boto3

def handler(event, context):
    ssm = boto3.client("ssm", region_name=os.environ["REGION"])
    params = ssm.get_parameters_by_path(Path=os.environ["PARAM_PREFIX"])
    return {
        "statusCode": 200,
        "body": json.dumps({
            "account_id": os.environ["ACCOUNT_ID"],
            "region": os.environ["REGION"],
            "app_config_env": os.environ["APP_CONFIG"],
            "ssm_live": {p["Name"]: p["Value"] for p in params["Parameters"]},
        })
    }
PYEOF
  (cd "$TMP_DIR" && zip -q function.zip index.py)
  cp "$TMP_DIR/function.zip" lambda.zip
fi

terraform init -upgrade
terraform apply -auto-approve

echo ""
echo "Outputs:"
terraform output
