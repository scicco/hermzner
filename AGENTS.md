# Hermzner — Hermes Agent Provisioning

## Project Overview

Provision a hardened Hetzner VPS (Ubuntu 24.04) with rootless Podman and deploy Hermes Agent behind Tailscale. Terraform creates the VPS, Ansible configures it, a `deploy.sh` orchestrates both.

**Security baseline:** This project implements all 20 principles from [`COVENANT.md`](./COVENANT.md). Every role and template is designed to satisfy specific principles.

## Repository Layout

```
terraform/         → Hetzner VPS (main.tf, variables.tf, outputs.tf)
ansible/           → 5 roles + 2 playbooks + inventory/group_vars
  inventory/       → hosts.yml + group_vars/
  roles/
    podman/        → Rootless Podman, hermes user, subuid/subgid, linger
    tailscale/     → apt install, auth key, SSH enabled, IP registration
    security/      → UFW, sysctl hardening, unattended-upgrades, SSH policy, umask 077, fail2ban, disable unused services, /dev/shm hardening
    hermes/        → Quadlet (default) + Compose (fallback) templates, Dockerfile.mnemosyne.j2, secrets
    backup/        → daily local backups, optionally age-encrypted, 30-day retention
  playbooks/
    site.yml       → Preflight assertions → roles
    verify.yml     → 11 security invariants, fail-closed
deploy.sh          → Terraform → SSH readiness loop → Ansible → verify
teardown.sh        → terraform destroy + cleanup
scripts/
  restore.sh       → Restore from backup archive (plain or age-encrypted)
  repo_check.sh    → Local security and consistency checks
```

## Key Architecture Decisions

| Decision          | Choice                                                   | Rationale                                                                                                               |
| ----------------- | -------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Runtime backend   | Quadlet (default), Compose (fallback)                    | Quadlet gives cleaner systemd lifecycle; Compose for environments without systemd user sessions                         |
| Container runtime | Rootless Podman                                          | Principle 1 — dedicated `hermes` user, subuid/subgid, never root                                                        |
| Network access    | Tailscale SSH + tunnel                                   | No public port exposure; ports bound to `127.0.0.1`                                                                     |
| Ansible host      | Public IPv4 (initial)                                    | Ansible runs before Tailscale exists — connects via Hetzner-assigned IPv4, not Tailscale IP                             |
| Image pinning     | Digest required, fail-closed                             | Principle 10 — `hermes_image_ref` must contain `@sha256:`; override via `ALLOW_UNPINNED_IMAGE` env var (not group_vars) |
| Dashboard         | Disabled by default                                      | Principle 14 — `hermes_dashboard_enabled: false`, user opts in                                                          |
| Secret storage    | `/home/hermes/.hermes/.env` at `0600`                    | Principle 12 — generated via `openssl rand -hex 32`, never overwritten                                                  |
| Backup encryption | age (opt-in)                                             | Principle 6 — `backup_encryption_enabled` + `backup_age_recipient` (public key from deployer, not generated on-server)  |
| Token handling    | `TF_VAR_hcloud_token` env var                            | No `.tfvars` file on disk; Terraform reads from environment                                                             |
| SSH hardening     | Opt-in via `sshd_hardening_enabled`                      | Default `false` — Ubuntu cloud images ship secure defaults                                                              |
| fail2ban          | Enabled by default (`security_fail2ban_enabled`)         | Bans SSH IPs after 3 failed attempts within 10 minutes                                                                  |
| Unused services   | Disabled by default (`security_disable_unused_services`) | Stops + masks avahi-daemon, cups, ModemManager, multipathd, udisks2                                                     |
| Shared memory     | Hardened by default (`security_harden_shared_memory`)    | `/dev/shm` mounted with `noexec,nosuid,nodev`                                                                           |
| Memory backend    | Mnemosyne (opt-in via `hermes_mnemosyne_enabled`)        | SQLite-vec memory, custom Docker image built from pinned base, data in existing volume mount                           |

## Preflight Assertions (fail-closed)

Before any role executes, `site.yml` validates:

- `hermes_image_ref` is set and digest-pinned (unless `ALLOW_UNPINNED_IMAGE` env var is set)
- `api_server_cors_origins` is not `"*"`
- `hermes_runtime_backend` is `quadlet` or `compose`
- `public_ssh_policy` is `restricted`, `disabled_after_tailscale`, or `open_key_only`
- `podman_volume_label_suffix` is `""` or `":Z"`
- `hermes_bind_mode` is `localhost`
- `backup_age_recipient` is set if `backup_encryption_enabled=true`

## Security Verification (`verify.yml`)

After deployment, 11 checks must all pass:

1. Container not privileged
2. User namespace active
3. All capabilities dropped
4. `no-new-privileges` enabled
5. seccomp not disabled
6. AppArmor not disabled
7. Ports bound to `127.0.0.1`
8. Container runs as `hermes` user
9. Data dir `0700`
10. `.env` `0600`
11. Health endpoint responding

## Workflow

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit: set ssh_public_key, overrides
# Edit: set hermes_image_ref in ansible/inventory/group_vars/all.yml

HCLOUD_TOKEN=xxx TAILSCALE_AUTH_KEY=tskey-auth-xxx ./deploy.sh

## SSH as Root (VPS Operations)

When SSHed as root, all `hermes` user commands need:

```bash
cd /tmp && sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) <command>
```

- `cd /tmp` — sudo inherits cwd; hermes can't chdir to /root
- `XDG_RUNTIME_DIR` — required for rootless podman/systemd
- `sudo -u hermes` — run as the hermes user

Quadlet services use transient/generated units — use `start`/`restart`/`stop`, NOT `enable --now`:

```bash
sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) systemctl --user restart hermes.service
```

Hermes binary lives in a venv at `/opt/hermes/.venv/bin/hermes` — use full path in `podman exec`.

# Post-deploy (if hermes_start_runtime: false):
ssh hermes@<tailscale-ip>
podman run -it --rm -v /home/hermes/.hermes:/opt/data <image> setup
systemctl --user enable --now hermes.service

# Post-deploy (if mnemosyne enabled, after container running):
ssh hermes@<tailscale-ip>
cd /tmp && sudo -u hermes XDG_RUNTIME_DIR=/run/user/$(id -u hermes) podman exec -it hermes /opt/hermes/.venv/bin/hermes memory setup

# Teardown:
./teardown.sh

# Restore from backup:
./scripts/restore.sh /path/to/hermes-backup-20260521-020000.tar.gz
# Encrypted: ./scripts/restore.sh <file>.tar.gz.age --age-key ~/.age/key.txt
```

## Conventions

- **No hardcoded secrets** — `.env` generated at `0600`, `no_log: true` on sensitive tasks
- **Idempotent** — all roles check-before-act, secrets never overwritten
- **Image pinning required** — supply chain protection via digest enforcement
- **Explicit SSH key path** — override via `PRIVATE_SSH_KEY` env var, defaults to `~/.ssh/id_ed25519`
- **Host key verification** — `ssh-keyscan` saves to `known_hosts`; Ansible `host_key_checking` kept enabled
- **Token handling** — `TF_VAR_hcloud_token` env var; no `.tfvars` file on disk
- **Image pinning override** — `ALLOW_UNPINNED_IMAGE` env var (not `inventory/group_vars/all.yml`)
- **Custom image build** — `hermes_mnemosyne_enabled` triggers `podman build` from a Jinja2 Dockerfile; resulting image is `localhost/hermes-mnemosyne:latest`
