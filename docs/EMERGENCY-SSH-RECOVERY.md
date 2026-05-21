# Emergency SSH Recovery (Hetzner Rescue)

## When to use
- Locked out due to sshd_config (e.g., `AllowUsers` blocking root, broken config)
- Tailscale not working
- SSH access broken

---

## Step 1 — Enable Rescue System

1. Go to [Hetzner Cloud Console](https://console.hetzner.cloud)
2. Select the server
3. Click **Rescue** → **Enable Rescue**
4. Select **linux64** rescue image
5. Copy the **temporary root password** shown
6. Click **Enable** and then **Reboot**

---

## Step 2 — SSH into Rescue

```bash
ssh root@<server-ip>
```

Paste the temporary root password when prompted.

---

## Step 3 — Run Recovery Script

### Option A — Direct from GitHub (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/scicco/hermzner/main/docs/rescue-restore-ssh.sh | bash
```

### Option B — Paste manually

If the server has no internet access, copy the script from `docs/rescue-restore-ssh.sh` in the repo and paste it manually.

---

## Step 4 — Reboot

```bash
reboot
```

---

## Step 5 — Re-deploy (optional)

After recovery, re-run the deploy to re-apply correct configuration:

```bash
./deploy.sh
```

---

## Alternative Recovery Methods

| Method | When |
|--------|------|
| **Local script** — `ssh root@<tailscale-ip>` then `/root/revert-sshd-hardening.sh` | Tailscale still works |
| **Hetzner Console** — VNC web console at `console.hetzner.cloud` | No SSH at all, no rescue needed |
| **Rescue System + script** (this document) | All else fails |

---

## Prevention

Recovery should rarely be needed. This system is designed with:

- **Tailscale SSH** as primary access (bypasses sshd_config)
- **UFW deny** on public SSH when `public_ssh_policy: disabled_after_tailscale`
- **Canary check** before hardening (verifies Tailscale is reachable first)
- **Recovery script** installed at `/root/revert-sshd-hardening.sh` (if SSH still works)
