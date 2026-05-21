#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

usage() {
  echo "Usage: $0 <backup_file> [--tailscale-ip <ip>] [--age-key <path>]"
  echo ""
  echo "Restore a Hermes backup archive to a deployed server."
  echo ""
  echo "Arguments:"
  echo "  <backup_file>         Path to backup archive (.tar.gz or .tar.gz.age)"
  echo "  --tailscale-ip <ip>   Tailscale IP of server (auto-detected if omitted)"
  echo "  --age-key <path>      Age private key (required if backup is encrypted)"
  exit 1
}

# --- Phase 0: Parse arguments ---
BACKUP_FILE=""
TAILSCALE_IP=""
AGE_KEY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tailscale-ip)
      TAILSCALE_IP="$2"
      shift 2
      ;;
    --age-key)
      AGE_KEY="$2"
      shift 2
      ;;
    -*)
      usage
      ;;
    *)
      [ -z "$BACKUP_FILE" ] || usage
      BACKUP_FILE="$1"
      shift
      ;;
  esac
done

# --- Phase 1: Prerequisites ---
info "Checking prerequisites..."

[ -n "$BACKUP_FILE" ] || usage
[ -f "$BACKUP_FILE" ] || error "Backup file not found: $BACKUP_FILE"

SSH_KEY="${PRIVATE_SSH_KEY:-$HOME/.ssh/id_ed25519}"
[ -f "$SSH_KEY" ] || error "SSH key not found at $SSH_KEY"

IS_ENCRYPTED=false
if [[ "$BACKUP_FILE" == *.age ]]; then
  IS_ENCRYPTED=true
  [ -n "$AGE_KEY" ] || error "Backup is encrypted. Provide --age-key <path> to decrypt."
  [ -f "$AGE_KEY" ] || error "Age key not found: $AGE_KEY"
  command -v age >/dev/null 2>&1 || error "age is not installed locally"
fi

# --- Phase 2: Get Tailscale IP ---
if [ -z "$TAILSCALE_IP" ]; then
  info "Auto-detecting Tailscale IP..."
  SERVER_IP=$(terraform -chdir=terraform output -raw server_ipv4 2>/dev/null || echo "")
  if [ -n "$SERVER_IP" ]; then
    TAILSCALE_IP=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      root@"${SERVER_IP}" tailscale ip -4 2>/dev/null || echo "")
  fi
  [ -n "$TAILSCALE_IP" ] || error "Cannot auto-detect Tailscale IP. Provide --tailscale-ip <ip>"
  info "Detected Tailscale IP: ${TAILSCALE_IP}"
fi

info "Verifying SSH access to ${TAILSCALE_IP}..."
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@"${TAILSCALE_IP}" id >/dev/null 2>&1 \
  || error "Cannot SSH to root@${TAILSCALE_IP}"

# --- Phase 3: Decrypt if needed ---
DECRYPTED_BACKUP="$BACKUP_FILE"
if $IS_ENCRYPTED; then
  info "Decrypting backup with age..."
  DECRYPTED_BACKUP="${BACKUP_FILE%.age}"
  age -d -i "$AGE_KEY" -o "$DECRYPTED_BACKUP" "$BACKUP_FILE" || error "age decryption failed"
  info "Decrypted to: ${DECRYPTED_BACKUP}"
fi

# --- Phase 4: SCP to server ---
info "Copying backup to server..."
REMOTE_FILE="/home/hermes/hermes-restore.tar.gz"
scp -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
  "$DECRYPTED_BACKUP" root@"${TAILSCALE_IP}":"${REMOTE_FILE}" \
  || error "SCP failed"

# --- Phase 5: Stop runtime ---
info "Stopping Hermes runtime (if running)..."
ssh root@"${TAILSCALE_IP}" '
  sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) systemctl --user stop hermes.service 2>/dev/null || true
  podman stop hermes 2>/dev/null || true
' || true

# --- Phase 6: Extract backup ---
info "Extracting backup..."
ssh root@"${TAILSCALE_IP}" "
  sudo -u hermes tar xzf \"${REMOTE_FILE}\" -C /home/hermes/ && \
  rm -f \"${REMOTE_FILE}\"
" || error "Extraction failed"

# --- Phase 7: Fix permissions ---
info "Fixing permissions..."
ssh root@"${TAILSCALE_IP}" '
  chown -R hermes:hermes /home/hermes/.hermes && \
  chmod 0700 /home/hermes/.hermes && \
  [ -f /home/hermes/.hermes/.env ] && chmod 0600 /home/hermes/.hermes/.env || true
' || error "Permission fix failed"

# Check if .env was restored
ssh root@"${TAILSCALE_IP}" '[ -f /home/hermes/.hermes/.env ]' 2>/dev/null \
  || warn "No .env found in backup — run interactive setup to generate one"

# --- Phase 8: Start runtime ---
info "Starting Hermes runtime..."
ssh root@"${TAILSCALE_IP}" '
  sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) systemctl --user daemon-reload && \
  sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) systemctl --user start hermes.service
' || error "Failed to start runtime"

# Give the container a moment to start
sleep 3

# --- Phase 9: Verify ---
if [ -f ansible/inventory/hosts.yml ]; then
  info "Running verification playbook..."
  ansible-playbook ansible/playbooks/verify.yml || warn "Verify playbook reported errors — check output above"
else
  info "Recreating inventory for verification..."
  mkdir -p ansible/inventory
  cat > ansible/inventory/hosts.yml <<EOF
all:
  hosts:
    hermes:
      ansible_host: ${TAILSCALE_IP}
      ansible_user: root
      ansible_ssh_private_key_file: ${SSH_KEY}
EOF
  ansible-playbook ansible/playbooks/verify.yml || warn "Verify playbook reported errors — check output above"
fi

# --- Phase 10: Summary ---
echo ""
info "Restore complete!"
echo ""
printf "  %-20s %s\n" "Backup:" "$(basename "$BACKUP_FILE")"
printf "  %-20s %s\n" "Server:" "root@${TAILSCALE_IP}"
printf "  %-20s %s\n" "Health:" "curl http://127.0.0.1:8642/health (via SSH tunnel)"
echo ""

if $IS_ENCRYPTED; then
  rm -f "$DECRYPTED_BACKUP"
fi
