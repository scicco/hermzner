#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "[INFO] Destroying Terraform resources..."
terraform -chdir=terraform destroy -auto-approve

echo "[INFO] Cleaning up inventory..."
rm -f ansible/inventory/hosts.yml

echo "[INFO] Teardown complete."
