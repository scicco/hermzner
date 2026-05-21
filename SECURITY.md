# Security Model

This document describes the security architecture, threat model, and design rationale for the Hermzner provisioning pipeline. It is intended to prevent incorrect assumptions when reviewing the system without full context.

---

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
                                    │    ├─ .env (0600)                │
                                    │    └─ data (0700)                │
                                    └──────────────────────────────────┘
```

---

## Trust Boundary

The primary trust boundary of this system is **Tailscale identity**, not SSH.

- SSH is treated as a transport layer
- Access control is identity-based (Tailscale)
- Services are not exposed publicly

Implications:

- Misconfigured SSH does not imply compromise
- Network surface is minimal
- Identity defines access

---

## Core Principles

- Minimize exposed surface
- Prefer identity-based access
- Avoid fragile configuration (e.g. AllowUsers)
- Fail safely and predictably
- Guarantee recoverability

---

## Key Design Decisions

### Quadlet as primary runtime

- Native systemd integration
- No Docker dependency
- Deterministic lifecycle

---

### Host key verification enabled

- known_hosts populated via ssh-keyscan
- No disabling of host key checking

---

### Secrets never logged

- Ansible `no_log: true`
- Covers Tailscale key and API key

---

### Localhost-only exposure

All services bind to:

```
127.0.0.1
```

No direct network exposure.

---

### Image digest pinning enforced

- Requires `@sha256:` digest
- Floating tags rejected
- Override only via env variable

---

### Verification is fail-closed

Deployment fails if any check fails:

- No privileged containers
- Capabilities dropped
- no-new-privileges
- localhost binding
- strict permissions

---

## Access Control Model

Primary access:

```
ssh root@<tailscale-ip>
```

Public SSH is configurable:

- disabled_after_tailscale
- restricted
- open_key_only

---

## SSH Hardening Philosophy

- Minimal
- Optional
- Never breaks access

Settings:

- PasswordAuthentication no
- PermitRootLogin prohibit-password
- ChallengeResponseAuthentication no
- MaxAuthTries 3
- MaxSessions 5

---

## Network Security

- UFW default deny
- SSH via tailscale0 or restricted IP
- No public service ports

---

## Container Security

- Rootless Podman
- No capabilities
- Read-only filesystem
- no-new-privileges
- Resource limits

---

## Secrets Handling

- Generated securely
- Stored with 0600
- Not logged

---

## Backup Security

- Stored locally
- 0600 permissions
- Optional encryption (age)

---

## Recovery Model

Recovery paths:

1. Tailscale SSH
2. Local recovery script
3. Hetzner Rescue system
4. Hetzner console

Guarantees:

- sshd config validated
- rollback on failure
- no permanent lockout

---

## Threat Model

### In Scope

- Container compromise
- Supply chain attacks
- Network exposure
- SSH brute force

### Out of Scope

- Deployer compromise
- Tailscale compromise
- Kernel 0-days
- Physical attacks

---

## Defense in Depth

- UFW
- Fail2Ban (optional)
- sysctl hardening
- disabled services

---

## Known Gaps

- No Terraform remote state
- No automatic image updates
- SSH hardening optional
- Env token visibility during deploy

---

## Final Note

Security is achieved through reduced exposure and guaranteed recovery, not complexity.
