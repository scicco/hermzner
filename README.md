# Hermzner

Provision a hardened Hermes Agent on Hetzner with rootless Podman and Tailscale.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/) >= 2.15
- [Hetzner Cloud API token](https://docs.hetzner.com/cloud/api/getting-started/generating-api-token)
- [Tailscale pre-auth key](https://tailscale.com/kb/1085/auth-keys) (reusable or ephemeral)

## Quick Start

```bash
# 1. Copy and edit Terraform variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vim terraform/terraform.tfvars

# 2. Copy and override Ansible defaults
vim ansible/group_vars/all.yml
# Required: set hermes_image_ref to a pinned digest

# 3. Deploy
HCLOUD_TOKEN=your_token TAILSCALE_AUTH_KEY=tskey-auth-... ./deploy.sh
```

## What Gets Deployed

| Component | Detail |
|-----------|--------|
| VPS | Hetzner cx23, Ubuntu 24.04 |
| Container Runtime | Rootless Podman (Quadlet default, Compose fallback) |
| Network | Tailscale SSH + subnet access |
| Service | Hermes Agent (gateway, API, optional dashboard) |
| Backups | Daily encrypted (via age) to /home/hermes/backups/ |

## Security Controls

- Rootless container, all capabilities dropped, no-new-privileges
- All ports bound to 127.0.0.1 (access via Tailscale SSH tunnel)
- UFW default deny, only tailscale0 allowed
- Read-only root filesystem, tmpfs for /tmp and /run
- API key auto-generated, .env at 0600
- Image digest pinning required (fail-closed if missing)

See [`SECURITY.md`](./SECURITY.md) for the full security model, threat model, and design rationale.

## Post-Deployment

```bash
# Access dashboard via SSH tunnel
ssh -L 9119:127.0.0.1:9119 hermes@<tailscale-ip>

# Open http://127.0.0.1:9119 in browser
```

## Directory Structure

```
terraform/       # Hetzner VPS provisioning
ansible/         # Server configuration (5 roles)
deploy.sh        # One-command deploy
teardown.sh      # Destroy everything
```

## Customization

See `ansible/group_vars/all.yml` for all configurable options.
