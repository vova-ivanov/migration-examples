#!/usr/bin/env zsh
set -euo pipefail

# Empty the S3 bucket before destroy so Terraform can delete it
BUCKET=$(terraform output -raw shared_bucket 2>/dev/null || true)
if [[ -n "$BUCKET" ]]; then
  echo "Emptying bucket: $BUCKET"
  aws s3 rm "s3://${BUCKET}" --recursive 2>/dev/null || true
fi

terraform destroy -auto-approve
rm -f lambda.zip
