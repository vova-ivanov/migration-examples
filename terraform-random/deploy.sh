#!/usr/bin/env zsh
set -euo pipefail

terraform init
terraform apply -auto-approve

echo ""
echo "Outputs:"
terraform output
