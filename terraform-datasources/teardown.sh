#!/usr/bin/env zsh
set -euo pipefail

terraform destroy -auto-approve
rm -f lambda.zip
