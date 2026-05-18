# Secure Provisioning Principles for Hermes Agent on Podman

## Purpose

This document defines the security principles that an automation agent **MUST**, **SHOULD**, and **MUST NOT** follow when provisioning a server, installing Podman, and deploying Hermes Agent through a Docker Compose-compatible workflow.

Hermes Agent is a powerful automation service that may store API keys, sessions, memories, skills, configuration, and other sensitive data in its persistent data directory. The official Hermes container documentation states that user data, API keys, sessions, skills, and memories are stored in the host-mounted `/opt/data` directory.

Because Hermes Agent can automate actions, use credentials, and expose gateway/API functionality, the deployment must be treated as a security-sensitive service rather than a simple stateless container.

---

## 1. Rootless-First Execution

### Principle

The agent **MUST** install and configure Podman for rootless execution and **MUST NOT** run Hermes Agent as root unless there is a documented and approved exception.

### Requirements

- Create a dedicated Unix user, for example `hermes`.
- Configure subordinate UID/GID ranges for rootless Podman.
- Run all Hermes containers as the dedicated user.
- Avoid using the host root account for routine container lifecycle operations.

Rootless Podman requires subordinate UID and GID mappings in `/etc/subuid` and `/etc/subgid`.

### Example

```bash
useradd -m -s /bin/bash hermes
usermod --add-subuids 200000-265535 --add-subgids 200000-265535 hermes
```

The automation agent should validate that rootless Podman works before deploying Hermes.

---

## 2. Least-Privilege Container Runtime

### Principle

The Hermes container **MUST** be launched with the minimum privileges required to operate.

### Requirements

The agent **MUST NOT** use:

```bash
--privileged
--pid=host
--ipc=host
--net=host
-v /:/host
-v /var/run/docker.sock:/var/run/docker.sock
```

Privileged containers disable important isolation mechanisms and may expose host process tables, network interfaces, IPC resources, and host filesystems to the container.

### Required Runtime Controls

The agent **SHOULD** apply:

```bash
--cap-drop=ALL
--security-opt=no-new-privileges
```

`no-new-privileges` prevents container processes from gaining additional privileges.

---

## 3. No Public Exposure by Default

### Principle

Hermes Agent network services **MUST NOT** be exposed directly to the public Internet by default.

### Requirements

- Bind Hermes API ports to localhost unless explicitly configured otherwise.
- Use VPN, SSH tunneling, a private network, or a reverse proxy with strong authentication for remote access.
- Apply firewall rules before starting the service.
- Do not publish dashboard or API ports broadly.

### Preferred Binding

```yaml
ports:
  - "127.0.0.1:8642:8642"
```

### Avoid

```yaml
ports:
  - "8642:8642"
```

unless the deployment has explicit firewalling, authentication, and monitoring controls.

---

## 4. Strong API Authentication

### Principle

If the Hermes API server is enabled, the automation agent **MUST** configure strong authentication.

### Requirements

- Generate a high-entropy API key.
- Do not use default, short, predictable, or hardcoded API keys.
- Store secrets in a protected environment file.
- Set restrictive file permissions on secret files.
- Avoid logging secrets.

### Example

```bash
install -d -m 700 -o hermes -g hermes /home/hermes/.hermes
openssl rand -hex 32 > /home/hermes/.hermes/api_server_key
chmod 600 /home/hermes/.hermes/api_server_key
chown hermes:hermes /home/hermes/.hermes/api_server_key
```

---

## 5. Restrictive CORS Configuration

### Principle

The automation agent **MUST NOT** configure permissive CORS unless explicitly required and approved.

### Requirements

- Avoid `API_SERVER_CORS_ORIGINS=*`.
- Restrict CORS to known trusted origins.
- Disable browser-facing access if not required.

### Preferred

```yaml
environment:
  API_SERVER_CORS_ORIGINS: "https://trusted.example.org"
```

### Avoid

```yaml
environment:
  API_SERVER_CORS_ORIGINS: "*"
```

---

## 6. Persistent Data Protection

### Principle

The Hermes persistent data directory is sensitive and **MUST** be protected as a secrets-bearing directory.

### Requirements

- Use a dedicated host directory for Hermes data.
- Set permissions to `0700`.
- Ensure ownership belongs only to the dedicated Hermes user.
- Do not mount broad host paths.
- Do not mount SSH keys, cloud credentials, home directories, source repositories, or container engine sockets unless explicitly required and approved.

Hermes stores configuration, API keys, sessions, skills, memories, and other user data in a host-mounted directory at `/opt/data`.

### Example

```bash
install -d -m 700 -o hermes -g hermes /home/hermes/.hermes
```

### Compose Mount

```yaml
volumes:
  - /home/hermes/.hermes:/opt/data:Z
```

On SELinux-enabled hosts, use `:Z` for a private container label when the volume is not shared between containers.

---

## 7. Mandatory Linux Security Controls

### Principle

The automation agent **MUST** preserve Linux container confinement controls.

### Requirements

The agent **MUST NOT** disable:

```bash
--security-opt label=disable
--security-opt seccomp=unconfined
--security-opt apparmor=unconfined
```

### Required

- Keep seccomp enabled.
- Keep SELinux labels enabled where SELinux is available.
- Keep AppArmor enabled where AppArmor is available.
- Use private SELinux volume labeling with `:Z` where appropriate.

---

## 8. Read-Only Runtime Filesystem Where Possible

### Principle

The Hermes container filesystem **SHOULD** be read-only during normal operation.

### Requirements

- Use a read-only root filesystem where possible.
- Provide writable storage only for `/opt/data`.
- Use `tmpfs` for temporary runtime paths.
- Avoid broad writable mounts.

### Example Podman Runtime Options

```bash
--read-only
--read-only-tmpfs=true
--tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m
```

If Hermes setup requires temporary write access, the automation agent may run a one-time setup phase with relaxed settings, then switch back to a hardened runtime profile.

---

## 9. Resource Limits and Abuse Resistance

### Principle

The automation agent **SHOULD** apply resource limits to reduce denial-of-service risk.

### Requirements

Set reasonable limits for:

- memory
- CPU
- process count
- restart behavior
- log size, where supported

### Example

```bash
--memory=2g
--cpus=2
--pids-limit=512
--restart=unless-stopped
```

The exact values should be configurable according to host size and expected workload.

---

## 10. Trusted Image and Supply Chain Hygiene

### Principle

The automation agent **MUST** pull Hermes images from trusted sources and **SHOULD** pin image versions or digests.

### Requirements

- Avoid unreviewed third-party images.
- Prefer pinned tags or digests.
- Record the deployed image reference.
- Support controlled upgrades.
- Allow image scanning where available.
- Do not automatically run arbitrary latest images in sensitive environments.

### Preferred

```yaml
image: docker.io/nousresearch/hermes-agent:<pinned-version>
```

or:

```yaml
image: docker.io/nousresearch/hermes-agent@sha256:<digest>
```

### Avoid for production

```yaml
image: docker.io/nousresearch/hermes-agent:latest
```

unless the deployment explicitly accepts automatic behavior changes.

---

## 11. Controlled Skills, Tools, and Extensions

### Principle

The automation agent **MUST** assume Hermes skills, tools, and extensions can expand the attack surface.

### Requirements

- Install only trusted skills or extensions.
- Do not enable arbitrary shell, browser, or host automation capabilities without explicit approval.
- Keep a list of enabled skills.
- Disable unused integrations.
- Review third-party extensions before installation.

---

## 12. Secret Handling and Rotation

### Principle

Secrets **MUST** be handled as high-value credentials.

### Requirements

- Never print secrets in logs.
- Never commit secrets to Git.
- Store secrets in protected files or secret management systems.
- Use `0600` permissions for environment files.
- Rotate API keys and tokens if exposure is suspected.
- Separate setup-time credentials from runtime credentials where possible.

### Example

```bash
touch /home/hermes/.hermes/.env
chmod 600 /home/hermes/.hermes/.env
chown hermes:hermes /home/hermes/.hermes/.env
```

---

## 13. Firewall and Network Policy Before Service Start

### Principle

The automation agent **MUST** configure network restrictions before starting Hermes.

### Requirements

- Default deny inbound traffic where possible.
- Permit only SSH administration and explicitly approved service ports.
- Bind Hermes API to `127.0.0.1` by default.
- If reverse proxying, expose only the proxy to the network.
- Do not expose the Hermes dashboard unless explicitly requested.

---

## 14. Dashboard Disabled by Default

### Principle

The Hermes dashboard **MUST** be disabled by default unless specifically requested.

### Requirements

- Do not set `HERMES_DASHBOARD=1` by default.
- If enabled, bind it to localhost.
- Protect it behind authentication or VPN.
- Do not expose port `9119` publicly.

---

## 15. Idempotent and Auditable Automation

### Principle

The provisioning agent **MUST** be idempotent, auditable, and safe to re-run.

### Requirements

The agent should:

- Check whether users, directories, packages, services, and containers already exist.
- Avoid overwriting existing secrets.
- Record generated configuration.
- Log actions without leaking credentials.
- Produce a final deployment summary.
- Validate that the running container matches the intended security profile.

### Required Validation Commands

```bash
podman inspect hermes
podman ps
podman logs hermes
```

---

## 16. Compose Compatibility with Podman

### Principle

If Docker Compose syntax is used, the automation agent **MUST** ensure that the resulting deployment is executed through Podman-compatible tooling and preserves the same hardening semantics.

### Requirements

- Prefer `podman compose` or a tested Podman-compatible Compose implementation.
- Validate that security options are actually applied.
- Do not assume all Docker Compose options behave identically under Podman.
- Generate a deployment verification report after startup.

The agent must inspect the running container after deployment rather than assuming the Compose file was interpreted as intended.

---

## 17. Secure Default Compose Profile

### Principle

The generated Compose file **MUST** default to a secure local-only deployment.

### Example Hardened Compose File

```yaml
services:
  hermes:
    image: docker.io/nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped

    command: ["gateway", "run"]

    userns_mode: "keep-id"

    cap_drop:
      - ALL

    security_opt:
      - no-new-privileges

    read_only: true

    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=512m

    pids_limit: 512
    mem_limit: 2g
    cpus: 2

    ports:
      - "127.0.0.1:8642:8642"

    environment:
      API_SERVER_ENABLED: "true"
      API_SERVER_HOST: "0.0.0.0"
      API_SERVER_CORS_ORIGINS: "https://trusted.example.org"

    env_file:
      - /home/hermes/.hermes/.env

    volumes:
      - /home/hermes/.hermes:/opt/data:Z
```

The API server is bound to `0.0.0.0` inside the container so the process can listen within the container namespace, while the host port mapping restricts access to `127.0.0.1`.

---

## 18. One-Time Setup Mode Must Be Separated from Runtime Mode

### Principle

Initial Hermes setup and normal Hermes runtime **SHOULD** be treated as separate phases.

### Requirements

During setup, the agent may run:

```bash
podman run -it --rm \
  -v /home/hermes/.hermes:/opt/data:Z \
  docker.io/nousresearch/hermes-agent:latest \
  setup
```

After setup, the agent must deploy the hardened long-running service.

---

## 19. Post-Deployment Security Verification

### Principle

The automation agent **MUST** verify the final deployment.

### Required Checks

The agent must verify that:

- Hermes is running rootless.
- The container is not privileged.
- Host networking is not enabled.
- Host PID namespace is not enabled.
- Host IPC namespace is not enabled.
- Capabilities are dropped.
- `no-new-privileges` is enabled.
- The API port is bound to localhost unless explicitly overridden.
- The persistent data directory is owned by the Hermes user.
- Secret files are not world-readable.
- Dashboard is disabled unless explicitly requested.
- No broad host directories are mounted.

### Example

```bash
podman inspect hermes
podman port hermes
podman top hermes user huser
```

---

## 20. Failure Policy

### Principle

The automation agent **MUST fail closed**.

### Requirements

The agent must stop provisioning and report an error if:

- Podman rootless setup fails.
- Required subordinate UID/GID mappings are missing.
- The data directory permissions are unsafe.
- The API key is missing or weak.
- The requested configuration exposes Hermes publicly without explicit approval.
- Security options are unsupported or ignored.
- The container starts with privileged mode.
- The deployment requires mounting sensitive host paths without explicit approval.

---

## Final Security Baseline

A deployment is considered acceptable only if it satisfies the following baseline:

- Podman runs rootless under a dedicated user.
- Hermes is not privileged.
- No host namespaces are shared.
- All Linux capabilities are dropped by default.
- `no-new-privileges` is enabled.
- SELinux/AppArmor/seccomp are not disabled.
- Persistent data is stored in a dedicated `0700` directory.
- API access is localhost-only by default.
- A strong API key is generated and protected.
- CORS is restricted.
- Dashboard is disabled by default.
- Skills and extensions are trusted and minimal.
- Final runtime configuration is verified with `podman inspect`.

The provisioning agent must prioritize containment, least privilege, explicit exposure, auditable configuration, and safe failure over convenience.

---

## Source Links

- Hermes Agent Docker documentation: https://hermes-agent.nousresearch.com/docs/user-guide/docker/
- Podman rootless tutorial: https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md
- Podman run documentation: https://docs.podman.io/en/latest/markdown/podman-run.1.html
- Podman security options documentation: https://docs.podman.io/en/v4.6.0/markdown/options/security-opt.html
- Red Hat documentation on privileged containers and host exposure: https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/assembly_running-special-container-images
- QNAP Hermes Agent security and risk considerations: https://www.qnap.com/en/how-to/tutorial/article/how-to-deploy-and-configure-hermes-agent-on-qnap-nas-with-container-station
