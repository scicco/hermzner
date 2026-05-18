#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Phase 1: Prerequisite check
info "Checking prerequisites..."

command -v terraform >/dev/null 2>&1 || error "terraform is not installed"
command -v ansible-playbook >/dev/null 2>&1 || error "ansible-playbook is not installed"

SSH_KEY="${PRIVATE_SSH_KEY:-$HOME/.ssh/id_ed25519}"

[ -n "${HCLOUD_TOKEN:-}" ]       || error "HCLOUD_TOKEN is not set"
[ -n "${TAILSCALE_AUTH_KEY:-}" ] || error "TAILSCALE_AUTH_KEY is not set"

[ -f "$SSH_KEY" ] || error "SSH key not found at $SSH_KEY"

ALLOW_UNPINNED="${ALLOW_UNPINNED_IMAGE:-false}"

# Phase 2: Terraform apply
info "Applying Terraform..."
export TF_VAR_hcloud_token="${HCLOUD_TOKEN}"
terraform -chdir=terraform apply -auto-approve

# Phase 3: Extract server IP
SERVER_IP=$(terraform -chdir=terraform output -raw server_ipv4)
info "Server IP: ${SERVER_IP}"

mkdir -p ansible/inventory
cat > ansible/inventory/hosts.yml <<EOF
all:
  hosts:
    hermes:
      ansible_host: ${SERVER_IP}
      ansible_user: root
      ansible_ssh_private_key_file: ${SSH_KEY}
EOF
info "Inventory written to ansible/inventory/hosts.yml"

# Phase 4: Wait for SSH readiness
info "Waiting for SSH..."
mkdir -p ~/.ssh
RETRIES=10
DELAY=5
for i in $(seq 1 $RETRIES); do
  ssh-keyscan -H "${SERVER_IP}" 2>/dev/null >> ~/.ssh/known_hosts
  if ssh -o ConnectTimeout=5 root@"${SERVER_IP}" id >/dev/null 2>&1; then
    info "SSH ready (attempt ${i})"
    break
  fi
  if [ "$i" -eq "$RETRIES" ]; then
    error "SSH not ready after ${RETRIES} attempts"
  fi
  warn "SSH not ready, retrying in ${DELAY}s (attempt ${i}/${RETRIES})..."
  sleep "$DELAY"
  DELAY=$((DELAY * 2))
  [ "$DELAY" -gt 60 ] && DELAY=60
done

# Phase 5: Run Ansible site
info "Running Ansible site playbook..."
ansible-playbook ansible/playbooks/site.yml \
  --extra-vars "tailscale_auth_key=${TAILSCALE_AUTH_KEY} allow_unpinned_image=${ALLOW_UNPINNED}"

# Phase 6: Verify (only if runtime was started)
if grep -q "hermes_start_runtime: true" ansible/group_vars/all.yml 2>/dev/null; then
  info "Running verification playbook..."
  ansible-playbook ansible/playbooks/verify.yml
else
  warn "Hermes prepared but not started."
  echo ""
  echo "  1. SSH in:        ssh hermes@<tailscale-ip>"
  echo "  2. Interactive:    podman run -it --rm -v /home/hermes/.hermes:/opt/data <image> setup"
  echo "  3. Start runtime:  sudo -iu hermes systemctl --user enable --now hermes.service"
  echo "  4. Verify:         ansible-playbook ansible/playbooks/verify.yml"
fi

# Phase 7: Summary
TAILSCALE_IP=$(ssh -o ConnectTimeout=5 root@"${SERVER_IP}" tailscale ip -4 2>/dev/null || echo "(unknown)")
info "Deployment complete!"
echo ""
echo "  Server IP:     ${SERVER_IP}"
echo "  Tailscale IP:  ${TAILSCALE_IP}"
echo "  SSH (pub):     ssh root@${SERVER_IP}"
echo "  SSH (ts):      ssh hermes@${TAILSCALE_IP}"
echo ""
echo "  -------- SSH Hardening --------"
echo "  sshd_config hardening is DISABLED by default."
echo "  To enable: set sshd_hardening_enabled: true in ansible/group_vars/all.yml"
echo "  Then run ./deploy.sh again — Ansible applies the changes idempotently."
echo "  This disables password auth, restricts root login, and limits users/sessions."
echo "  Without it, SSH security relies on network controls (UFW + Tailscale)."
