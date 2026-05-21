#!/usr/bin/env bash
set -euo pipefail

fix_sshd_config() {
  local config="$1"
  local backup="${config}.bak.$(date +%s)"

  echo "[*] Backing up $config..."
  cp "$config" "$backup"

  echo "[*] Removing Allow/Deny directives..."
  sed -i '/^AllowUsers/d; /^DenyUsers/d; /^AllowGroups/d; /^DenyGroups/d' "$config"

  echo "[*] Setting safe defaults..."
  grep -q "^PasswordAuthentication" "$config" \
    && sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$config" \
    || echo "PasswordAuthentication no" >> "$config"

  grep -q "^PermitRootLogin" "$config" \
    && sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$config" \
    || echo "PermitRootLogin prohibit-password" >> "$config"

  echo "[*] Validating sshd config..."
  if ! sshd -t -f "$config"; then
    echo "[!] Config invalid, restoring backup..."
    cp "$backup" "$config"
    return 1
  fi

  echo "$backup"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  BACKUP=$(fix_sshd_config "/etc/ssh/sshd_config")

  echo "[*] Restarting sshd..."
  if systemctl restart sshd; then
    echo "[✓] SSH hardening reverted successfully"
  else
    echo "[!] sshd restart failed, restoring backup..."
    cp "$BACKUP" "/etc/ssh/sshd_config"
    exit 1
  fi
fi
