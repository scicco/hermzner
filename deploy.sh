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

# Phase 1b: Detect deployer IP for UFW restricted mode
DEPLOYER_IP=$(curl -sf --max-time 5 https://ifconfig.me 2>/dev/null || curl -sf --max-time 5 https://icanhazip.com 2>/dev/null || echo "")
if [ -z "$DEPLOYER_IP" ]; then
  warn "Could not detect deployer IP. UFW restricted mode will not add a source-IP allow rule."
  warn "SSH via Tailscale will still work."
fi

# Phase 2: Terraform apply
info "Applying Terraform..."
export TF_VAR_hcloud_token="${HCLOUD_TOKEN}"
terraform -chdir=terraform init -upgrade

# Import existing SSH key if stale from manual server deletion
STALE_KEY_NAME="${TF_VAR_server_name:-hermes}-deployer"
STALE_KEY_ID=$(curl -sf -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
  "https://api.hetzner.cloud/v1/ssh_keys?name=${STALE_KEY_NAME}" 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(d['ssh_keys'][0]['id']) if d.get('ssh_keys') else None" 2>/dev/null || echo "")
if [ -n "$STALE_KEY_ID" ]; then
  info "Importing existing SSH key (ID: ${STALE_KEY_ID}) into Terraform state..."
  terraform -chdir=terraform import hcloud_ssh_key.deployer "$STALE_KEY_ID" 2>/dev/null || true
fi

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
  ssh-keygen -R "${SERVER_IP}" 2>/dev/null || true
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
sort -u -o ~/.ssh/known_hosts ~/.ssh/known_hosts 2>/dev/null || true

# Phase 5: Run Ansible site
info "Running Ansible site playbook..."
ansible-playbook ansible/playbooks/site.yml \
  --extra-vars "tailscale_auth_key=${TAILSCALE_AUTH_KEY} allow_unpinned_image=${ALLOW_UNPINNED} deployer_ip=${DEPLOYER_IP:-}"

# Phase 6: Verify (only if runtime was started)
TAILSCALE_IP=$(ssh -o ConnectTimeout=5 root@"${SERVER_IP}" tailscale ip -4 2>/dev/null || echo "")
if [ -z "$TAILSCALE_IP" ]; then
  TAILSCALE_IP="(unknown)"
  warn "Could not determine Tailscale IP. The server may still be authenticating."
fi

TAILSCALE_DNS=$(ssh -o ConnectTimeout=5 root@"${SERVER_IP}" "tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get(\"Self\",{}).get(\"DNSName\",\"\").rstrip(\".\"))'" || echo "")
if [ -z "$TAILSCALE_DNS" ]; then
  TAILSCALE_DNS="(unknown)"
fi

HERMES_IMAGE=$(sed -n "s/^hermes_image_ref:[[:space:]]*'\(.*\)'/\1/p" ansible/inventory/group_vars/all.yml 2>/dev/null)
if grep -q '^hermes_mnemosyne_enabled:[[:space:]]*true' ansible/inventory/group_vars/all.yml 2>/dev/null; then
  HERMES_IMAGE="localhost/hermes-mnemosyne:latest"
fi
if grep -q '^hermes_start_runtime:[[:space:]]*true' ansible/inventory/group_vars/all.yml 2>/dev/null; then
  info "Running verification playbook..."
  ansible-playbook ansible/playbooks/verify.yml

  if grep -q '^hermes_mnemosyne_enabled:[[:space:]]*true' ansible/inventory/group_vars/all.yml 2>/dev/null; then
    echo ""
    echo "  -------- Mnemosyne Memory --------"
    echo "  Plugin installed automatically by Ansible."
    echo "  To select 'mnemosyne' as the active memory provider:"
    echo "    ssh hermes@${TAILSCALE_IP}"
    echo "    cd /tmp && sudo -u hermes XDG_RUNTIME_DIR=/run/user/\$(id -u hermes) podman exec -it hermes /opt/hermes/.venv/bin/hermes memory setup"
    echo "    # Select 'mnemosyne' from the provider list"
  fi
else
  warn "Hermes prepared but not started."
  echo ""
  echo "  1. SSH in:        ssh root@${TAILSCALE_IP}"
  echo "  2. Interactive:    cd /tmp && sudo -u hermes podman run -it --rm -v /home/hermes/.hermes:/opt/data ${HERMES_IMAGE:-<image>} setup"
  echo "  3. Start runtime:  sudo -u hermes XDG_RUNTIME_DIR=/run/user/\$(id -u hermes) systemctl --user start hermes.service"
  if grep -q '^hermes_mnemosyne_enabled:[[:space:]]*true' ansible/inventory/group_vars/all.yml 2>/dev/null; then
    echo "  4. Install plugin: sudo -u hermes XDG_RUNTIME_DIR=/run/user/\$(id -u hermes) podman exec hermes python3 -m mnemosyne.install"
    echo "  5. Load plugin:   sudo -u hermes XDG_RUNTIME_DIR=/run/user/\$(id -u hermes) systemctl --user restart hermes.service"
    echo "  6. Select memory:  cd /tmp && sudo -u hermes XDG_RUNTIME_DIR=/run/user/\$(id -u hermes) podman exec -it hermes /opt/hermes/.venv/bin/hermes memory setup"
    echo "  7. Verify:         ansible-playbook ansible/playbooks/verify.yml"
  else
    echo "  4. Verify:         ansible-playbook ansible/playbooks/verify.yml"
  fi
fi

# Phase 7: Summary
unset TF_VAR_hcloud_token
info "Deployment complete!"
echo ""
printf "  %-18s %s\n" "Server IP:" "${SERVER_IP}"
printf "  %-18s %s\n" "Tailscale IP:" "${TAILSCALE_IP}"
printf "  %-18s %s\n" "Tailscale DNS:" "${TAILSCALE_DNS}"
SSH_POLICY=$(grep '^public_ssh_policy:[[:space:]]*' ansible/inventory/group_vars/all.yml 2>/dev/null | sed 's/.*:[[:space:]]*//')
if [ "$SSH_POLICY" = "disabled_after_tailscale" ]; then
  printf "  %-18s %s\n" "SSH (pub):" "(disabled — use Tailscale SSH only)"
else
  printf "  %-18s %s\n" "SSH (pub):" "ssh root@${SERVER_IP}"
fi
printf "  %-18s %s\n" "SSH (ts-root):" "ssh root@${TAILSCALE_IP}"
if [ "${TAILSCALE_DNS}" != "(unknown)" ]; then
  printf "  %-18s %s\n" "SSH (ts-root DNS):" "ssh root@${TAILSCALE_DNS}"
fi
printf "  %-18s %s\n" "SSH (ts-user):" "ssh hermes@${TAILSCALE_IP}"
if [ "${TAILSCALE_DNS}" != "(unknown)" ]; then
  printf "  %-18s %s\n" "SSH (ts-user DNS):" "ssh hermes@${TAILSCALE_DNS}"
fi
echo ""
echo "  -------- Access (via SSH tunnel) --------"
echo "  Dashboard:  ssh -L 9119:127.0.0.1:9119 hermes@${TAILSCALE_IP}  → http://127.0.0.1:9119"
echo "  API:        ssh -L 8642:127.0.0.1:8642 hermes@${TAILSCALE_IP}  → http://127.0.0.1:8642"
echo ""
echo "  -------- SSH Hardening --------"
echo "  sshd_config hardening is DISABLED by default."
echo "  To enable: set sshd_hardening_enabled: true in ansible/inventory/group_vars/all.yml"
echo "  Then run ./deploy.sh again — Ansible applies the changes idempotently."
echo "  This disables password auth and limits auth attempts/sessions."
echo "  Without it, SSH security relies on network controls (UFW + Tailscale)."

if grep -q '^hermes_mnemosyne_enabled:[[:space:]]*true' ansible/inventory/group_vars/all.yml 2>/dev/null; then
  echo ""
  echo "  -------- Mnemosyne Memory --------"
  echo "  Custom image built with mnemosyne-memory[all]."
  echo "  Plugin installed automatically (mnemosyne_runtime role)."
  if ! grep -q '^hermes_start_runtime:[[:space:]]*true' ansible/inventory/group_vars/all.yml 2>/dev/null; then
    echo "  Remember to run:"
    echo "    podman exec hermes python3 -m mnemosyne.install"
    echo "    systemctl --user restart hermes.service"
  fi
  echo "  To select 'mnemosyne' as the active provider:"
  echo "    ssh hermes@${TAILSCALE_IP}"
  echo "    cd /tmp && sudo -u hermes XDG_RUNTIME_DIR=/run/user/\$(id -u hermes) podman exec -it hermes /opt/hermes/.venv/bin/hermes memory setup"
fi
