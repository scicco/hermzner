# Security Model

This document describes the security architecture, threat model, and design rationale for the Hermzner provisioning pipeline. It exists to prevent the wrong assumptions that commonly arise when reviewing this project without reading every role and template.

## Security Architecture

```
Deployer Machine                  Hetzner VPS (Ubuntu 24.04)
┌─────────────────────┐             ┌──────────────────────────────────┐
│  Terraform          │  SSH + API  │  UFW (default deny)              │
│  Ansible            │ ──────────► │    │                             │
│  deploy.sh          │             │    ├─ tailscale0: SSH (22)       │
│  HCLOUD_TOKEN  env  │             │    └─ (optional) deployer IP: 22 │
│  TAILSCALE_KEY  env │             │                                  │
└─────────────────────┘             │  Podman (rootless, hermes user)  │
                                    │    └─ hermes.container           │
  Tailscale                         │       ├─ 127.0.0.1:8642 (API)    │
  ┌────────────┐                    │       ├─ 127.0.0.1:9119 (dash)   │
  │ SSH tunnel │ ◄─── tailnet ───   │       ├─ read-only rootfs        │
  └────────────┘                    │       ├─ cap_drop: ALL           │
                                    │       └─ no-new-privileges       │
                                    │                                  │
                                    │  /home/hermes/.hermes/           │
                                    │    ├─ .env          (0600)       │
                                    │    └─ data           (0700)      │
                                    └──────────────────────────────────┘
```

## Key Design Decisions

### Quadlet is the default backend, not Docker Compose

The primary runtime path uses [Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) — Podman's native systemd unit generator — not Docker Compose. The Quadlet template (`ansible/roles/hermes/templates/hermes.container.j2`) produces a `.container` unit file that `systemctl --user` manages directly.

This means:

- No Docker dependency or YAML parsing ambiguity
- Clean integration with `loginctl enable-linger` for auto-start at boot
- Systemd handles restart policy, logging, and resource limits natively

A Compose fallback (`ansible/roles/hermes/templates/compose.yaml.j2`) exists for environments without systemd user sessions, selected via `hermes_runtime_backend: compose`.

### Host key verification is enabled

The `deploy.sh` orchestrator saves the server's SSH host key to `~/.ssh/known_hosts` using `ssh-keyscan -H` during the readiness loop. Ansible runs with `host_key_checking` enabled. Neither `deploy.sh` nor `ansible.cfg` sets `ANSIBLE_HOST_KEY_CHECKING=False`.

The MITM window is limited to the first TCP connection during the readiness retry loop, which uses `ssh -o StrictHostKeyChecking=accept-new`.

### Secrets in sensitive tasks are suppressed

Ansible's `no_log: true` is applied to:

- The Tailscale auth key (`tailscale up --ssh --auth-key <key>`)
- The Hermes API key generation (`openssl rand -hex 32` → `.env`)

Without this, Ansible would print both credentials to stdout on every run.

### All ports are bound to 127.0.0.1

Both the Quadlet and Compose templates bind Hermes ports to `127.0.0.1` only:

- `8642` (Hermes API)
- `9119` (Hermes dashboard)

These ports are unreachable from the network — they can only be accessed through an SSH tunnel (`ssh -L 9119:127.0.0.1:9119 hermes@<tailscale-ip>`). Rootless Podman's user-mode networking (`slirp4netns`/`pasta`) operates in a separate namespace, and the `127.0.0.1` host binding means nothing on the network can reach these ports. UFW does not need to block them.

### Image digest pinning is enforced, not hardcoded

`hermes_image_ref: ""` defaults to **empty**. Deployment will fail until you set a pinned digest:

```yaml
hermes_image_ref: docker.io/nousresearch/hermes-agent@sha256:<digest>
```

The `allow_unpinned_image: false` default means any floating tag (`:latest`, `:stable`) triggers a preflight failure — even a non-empty reference without `@sha256:` is rejected. This is checked before any role executes.

### The verification playbook runs 9 checks, fail-closed

`ansible/playbooks/verify.yml` validates:

1. Container is not privileged
2. User namespace is active
3. All capabilities are dropped
4. `no-new-privileges` is enabled
5. Ports are bound to `127.0.0.1`
6. Container processes run as the `hermes` user
7. Data directory is `0700`
8. `.env` file is `0600`
9. Health endpoint responds on port `8642`

If any check fails, the playbook exits non-zero. No partial pass.

### Firewall is interface-specific, not subnet-based

UFW allows SSH on the `tailscale0` interface, not on the Tailscale CGNAT subnet (`100.x.y.z/10`). This means only traffic arriving through the `tailscale0` interface is permitted — if Tailscale is down, SSH over that path is unavailable (by design, for the `disabled_after_tailscale` policy).

## Threat Model

### In Scope

| Threat                               | Mitigation                                                                                                                  |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| Compromised Hermes Agent             | Rootless container, all capabilities dropped, read-only rootfs, `no-new-privileges`, `pids_limit`/`mem_limit`/`cpus` limits |
| Supply chain attack on Hermes image  | Digest pinning enforced at deploy time; `allow_unpinned_image: false` blocks floating tags                                  |
| Network-level attack on Hermes ports | Ports bound to `127.0.0.1`, unreachable from the network; UFW default deny inbound                                          |
| API key exposure                     | `openssl rand -hex 32` (256-bit), stored at `0600`, generated with `no_log: true`                                           |
| Unauthorized SSH access              | UFW restricts to `tailscale0` interface or specific deployer IP; Tailscale SSH requires valid tailnet identity              |
| Automated security updates           | `unattended-upgrades` enabled for OS packages                                                                               |
| Brute-force container process limits | `pids_limit: 512`, `mem_limit: 2g`, `cpus: 2`                                                                               |

### Out of Scope

| Threat                                | Rationale                                                                                                                                                                                                                    |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Compromised deployer machine          | If the machine running Terraform/Ansible is compromised, all secrets (`HCLOUD_TOKEN`, `TAILSCALE_AUTH_KEY`) and infrastructure are accessible. Mitigation requires hardware-backed secrets management (out of scope for MVP) |
| Compromised Tailscale control plane   | Tailscale manages its own authentication and key distribution. Trusting Tailscale is a design choice, not a gap we mitigate server-side                                                                                      |
| Denial of service against Hetzner API | Terraform uses Hetzner's public API. If it's unavailable, provisioning fails — no side-channel risk                                                                                                                          |
| Physical access to Hetzner hardware   | Hetzner is responsible for physical security                                                                                                                                                                                 |
| Container escape via kernel 0-days    | Rootless Podman reduces blast radius but doesn't prevent kernel-level escapes. Defense-in-depth through capability dropping, seccomp, AppArmor                                                                               |

## Known Gaps

These are intentional for the MVP but worth addressing in a production-hardened iteration:

1. **No `sshd_config` hardening** — SSH security relies on network-layer controls (UFW + Tailscale) rather than sshd-level configuration. Ubuntu 24.04 defaults are secure (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`), but explicit settings would be defense-in-depth.

2. **`HCLOUD_TOKEN` written unencrypted to disk** — The token ends up in `terraform.tfvars` on the deployer machine. This could be avoided with `sops`, `pass`, or HashiCorp Vault integration.

3. **No Terraform remote state** — State is stored locally in `terraform.tfstate`. Team operations or machine loss would be destructive. A `backend "s3"` or similar should be configured for shared use.

4. **No automated image digest updates** — Pinning to a digest means no automatic updates for the Hermes Agent image. Updates require manually changing `hermes_image_ref` in `group_vars/all.yml`.

5. **`allow_unpinned_image` bypass** — Setting this to `true` in `group_vars/all.yml` disables digest pinning. The same config file controls both the pinning requirement and its override. A separate mechanism (env var, separate config file) would be stronger.

## Security Principles

This project implements all 20 principles from [`secure-hermes-podman-provisioning-principles.md`](./secure-hermes-podman-provisioning-principles.md). See the principle coverage table in `docs/superpowers/specs/2026-05-18-hermes-podman-provisioning-design.md` for the full mapping from principle to implementation.

## Reporting a Vulnerability

This project provisions infrastructure for personal/learning use. If you find a vulnerability, open an issue on GitHub.
