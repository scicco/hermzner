#!/usr/bin/env bash
set -euo pipefail

echo "[*] Starting Hetzner rescue recovery..."

detect_root() {
  ROOT_DEV=$(lsblk -pnlo NAME,FSTYPE,MOUNTPOINT | awk '$2 ~ /ext4|xfs/ && $3 == "" {print $1; exit}')

  if [ -z "${ROOT_DEV:-}" ]; then
    echo "[!] Auto-detect failed, trying fallback..."
    ROOT_DEV=$(findmnt -n -o SOURCE / 2>/dev/null || true)
  fi

  if [ -z "${ROOT_DEV:-}" ]; then
    echo "[!] Could not auto-detect root partition"
    echo "[!] Available disks:"
    lsblk
    exit 1
  fi

  echo "[*] Using root device: $ROOT_DEV"
}

mount_root() {
  echo "[*] Mounting filesystem..."
  mkdir -p /mnt/recovery
  mount "$ROOT_DEV" /mnt/recovery
}

bind_mounts() {
  echo "[*] Preparing chroot..."
  mount --bind /dev /mnt/recovery/dev
  mount --bind /proc /mnt/recovery/proc
  mount --bind /sys /mnt/recovery/sys
}

fix_sshd() {
  echo "[*] Fixing SSH configuration inside chroot..."

  chroot /mnt/recovery /bin/bash << 'CHROOT_EOF'
set -e

if [ -f /root/revert-sshd-hardening.sh ]; then
  source /root/revert-sshd-hardening.sh
  if ! BACKUP=$(fix_sshd_config "/etc/ssh/sshd_config"); then
    echo "[!] Failed to fix sshd config"
    exit 1
  fi
else
  SSHD_CONFIG="/etc/ssh/sshd_config"
  BACKUP="${SSHD_CONFIG}.bak.$(date +%s)"
  cp "$SSHD_CONFIG" "$BACKUP"
  sed -i '/^AllowUsers/d; /^DenyUsers/d; /^AllowGroups/d; /^DenyGroups/d' "$SSHD_CONFIG"
  grep -q "^PasswordAuthentication" "$SSHD_CONFIG" \
    && sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG" \
    || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
  grep -q "^PermitRootLogin" "$SSHD_CONFIG" \
    && sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG" \
    || echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
  if ! sshd -t -f "$SSHD_CONFIG"; then
    cp "$BACKUP" "$SSHD_CONFIG"
    echo "[!] sshd config invalid, restored backup"
    exit 1
  fi
fi

echo "[*] Ensuring SSH service will start on boot (best-effort)..."
systemctl enable ssh 2>/dev/null || systemctl enable sshd 2>/dev/null || true

echo "[✓] SSH config repaired."
CHROOT_EOF
}

cleanup() {
  echo "[*] Cleaning up mounts..."
  umount /mnt/recovery/dev 2>/dev/null || true
  umount /mnt/recovery/proc 2>/dev/null || true
  umount /mnt/recovery/sys 2>/dev/null || true
  umount /mnt/recovery 2>/dev/null || true
}

detect_root
mount_root
bind_mounts
fix_sshd
cleanup

echo "[✓] Recovery complete. Reboot the server: reboot"
