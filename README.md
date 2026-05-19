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

# 2b. For manual Ansible runs (without deploy.sh):
cp ansible/inventory/hosts.yml.example ansible/inventory/hosts.yml
# Edit ansible_host and ansible_ssh_private_key_file to match your server
# (deploy.sh creates this file automatically — skip if using the one-command flow)

# 3. Deploy
HCLOUD_TOKEN=your_token TAILSCALE_AUTH_KEY=tskey-auth-... ./deploy.sh
```

## Smoke Test Deployment

Use this procedure for a first disposable test deployment. The goal is to validate Terraform, Ansible, Tailscale access, rootless Podman, and the Hermes runtime wiring before using a pinned production image.

> **Important:** Run this only against a disposable Hetzner VPS. The smoke test may use `ALLOW_UNPINNED_IMAGE=true` for convenience. Do not use this override for production.

### 1. Prepare local variables

Create and edit the Terraform variables file:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
vim terraform/terraform.tfvars
```

## What Gets Deployed

| Component | Detail |
|-----------|--------|
| VPS | Hetzner cx23, Ubuntu 24.04 |
| Container Runtime | Rootless Podman (Quadlet default, Compose fallback) |
| Network | Tailscale SSH + subnet access |
| Service | Hermes Agent (gateway, API, optional dashboard) |
| Backups | Daily local backups to /home/hermes/backups/; optionally encrypted with age |

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
  inventory/
    hosts.yml.example  # Template — copy to hosts.yml for manual Ansible runs
deploy.sh        # One-command deploy (auto-generates hosts.yml)
teardown.sh      # Destroy everything
```

## Customization

See `ansible/group_vars/all.yml` for all configurable options.
