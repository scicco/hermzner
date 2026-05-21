#!/usr/bin/env bash
set -u
set -o pipefail

# repo-checks.sh
# Local security/design consistency checks for hermzner.
#
# Usage:
#   chmod +x repo-checks.sh
#   ./repo-checks.sh
#
# Optional:
#   ./repo-checks.sh /path/to/hermzner

REPO_DIR="${1:-.}"
cd "$REPO_DIR" || {
  echo "ERROR: cannot cd into $REPO_DIR"
  exit 1
}

if [ ! -d ".git" ] && [ ! -d "ansible" ] && [ ! -d "terraform" ]; then
  echo "WARNING: this does not look like the hermzner repo root."
  echo "Current directory: $(pwd)"
fi

REPORT="hermzner-local-check-report.txt"

: > "$REPORT"

section() {
  local title="$1"
  {
    echo
    echo "================================================================================"
    echo "$title"
    echo "================================================================================"
  } | tee -a "$REPORT"
}

run_check() {
  local title="$1"
  shift

  section "$title"

  echo "+ $*" | tee -a "$REPORT"

  # Do not stop the whole script if a grep finds nothing.
  "$@" 2>&1 | tee -a "$REPORT"
  local status="${PIPESTATUS[0]}"

  echo | tee -a "$REPORT"
  echo "Exit status: $status" | tee -a "$REPORT"

  return 0
}

run_grep() {
  local title="$1"
  local pattern="$2"
  shift 2

  section "$title"

  echo "+ grep -RInE '$pattern' $*" | tee -a "$REPORT"

  grep -RInE "$pattern" "$@" 2>/dev/null | tee -a "$REPORT"
  local status="${PIPESTATUS[0]}"

  if [ "$status" -eq 1 ]; then
    echo "(no matches)" | tee -a "$REPORT"
  else
    echo "grep exit status: $status" | tee -a "$REPORT"
  fi

  return 0
}

run_grep_fixed() {
  local title="$1"
  local pattern="$2"
  shift 2

  section "$title"

  echo "+ grep -RIn '$pattern' $*" | tee -a "$REPORT"

  grep -RIn "$pattern" "$@" 2>/dev/null | tee -a "$REPORT"
  local status="${PIPESTATUS[0]}"

  if [ "$status" -eq 1 ]; then
    echo "(no matches)" | tee -a "$REPORT"
  else
    echo "grep exit status: $status" | tee -a "$REPORT"
  fi

  return 0
}

echo "Hermzner local repository checks"
echo "Repository: $(pwd)"
echo "Report: $REPORT"
echo

section "0. Git status and current commit"
{
  echo "+ git status --short"
  git status --short 2>/dev/null || true
  echo
  echo "+ git rev-parse --short HEAD"
  git rev-parse --short HEAD 2>/dev/null || true
  echo
  echo "+ git remote -v"
  git remote -v 2>/dev/null || true
} | tee -a "$REPORT"

run_check \
  "1. File tree" \
  find . -maxdepth 5 -type f -not -path "./.git/*" -print

run_grep \
  "2. Potential secret leakage scan" \
  "(tskey-|HCLOUD_TOKEN|TF_VAR_hcloud_token|hcloud_token|API_SERVER_KEY|BEGIN OPENSSH|BEGIN RSA|BEGIN EC PRIVATE|BEGIN PRIVATE KEY|password|passwd|token|secret|api[_-]?key)" \
  . \
  --exclude-dir=.git \
  --exclude-dir=.terraform \
  --exclude="*.md" \
  --exclude="*.lock.hcl" \
  --exclude="hermzner-local-check-report.txt" \
  --exclude="repo_check.sh"


run_grep_fixed \
  "3. Tailscale auth key and no_log usage" \
  "tailscale_auth_key\|no_log" \
  ansible

run_grep \
  "4. Image pinning enforcement" \
  "hermes_image_ref|ALLOW_UNPINNED_IMAGE|@sha256|allow_unpinned_image" \
  ansible README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "5. Port exposure check: 8642, 9119, 0.0.0.0, 127.0.0.1" \
  "8642|9119|0\.0\.0\.0|127\.0\.0\.1" \
  ansible terraform README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "6. Dangerous container flags or mounts" \
  "privileged|network[=:]host|--net=host|pid[=:]host|--pid=host|ipc[=:]host|--ipc=host|/var/run/docker\.sock|/:\s*/|source=/,|type=bind,source=/" \
  ansible terraform README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "7. Quadlet path and hermes.container references" \
  "containers/systemd|hermes\.container|systemctl --user|loginctl enable-linger|enable-linger" \
  ansible README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "8. Verification logic references" \
  "podman inspect|podman port|podman top|curl|/health|no-new-privileges|CapDrop|cap_drop|Privileged|Userns|userns" \
  ansible/playbooks ansible/roles 2>/dev/null

run_grep \
  "9. Environment file and API key handling" \
  "API_SERVER_KEY|\.env|0600|openssl rand|no_log|creates:|stat:" \
  ansible README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "10. Backup handling and encryption" \
  "backup_encryption_enabled|backup_age_recipient|age |age-|tar|backups|0600|0700|retention" \
  ansible README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "11. Firewall and SSH exposure checks" \
  "ufw|firewall|tailscale0|22/tcp|sshd|PasswordAuthentication|PermitRootLogin|public_ssh_policy|fail2ban" \
  ansible terraform README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

section "12. Terraform state tracking check"

echo "+ git ls-files | grep tfstate" | tee -a "$REPORT"
git ls-files | grep tfstate | tee -a "$REPORT"

if git ls-files | grep -q tfstate; then
  echo "❌ ERROR: tfstate files are tracked in git!" | tee -a "$REPORT"
else
  echo "✅ OK: no tfstate files tracked" | tee -a "$REPORT"
fi

run_grep \
  "13. Podman rootless setup checks" \
  "subuid|subgid|fuse-overlayfs|podman info|rootless|keep-id|linger|hermes" \
  ansible README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

run_grep \
  "14. Runtime backend branching checks" \
  "hermes_runtime_backend|quadlet|compose|podman-compose|compose.yaml|hermes.container" \
  ansible README.md SECURITY.md AGENTS.md COVENANT.md 2>/dev/null

section "15. Basic shell syntax check"

SHELL_FILES="$(find . -maxdepth 4 -type f \( -name "*.sh" -o -path "./deploy.sh" -o -path "./teardown.sh" \) -not -path "./.git/*" 2>/dev/null)"

if [ -z "$SHELL_FILES" ]; then
  echo "No shell files found." | tee -a "$REPORT"
else
  for f in $SHELL_FILES; do
    echo "+ bash -n $f" | tee -a "$REPORT"
    if bash -n "$f" 2>&1 | tee -a "$REPORT"; then
      echo "OK: $f" | tee -a "$REPORT"
    else
      echo "FAIL: $f" | tee -a "$REPORT"
    fi
    echo | tee -a "$REPORT"
  done
fi

section "16. YAML parse check if Python + PyYAML are available"

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY' 2>&1 | tee -a "$REPORT"
import pathlib
import sys

try:
    import yaml
except Exception as e:
    print("PyYAML not available; skipping YAML parse check.")
    sys.exit(0)

paths = []
for root in ["ansible"]:
    p = pathlib.Path(root)
    if p.exists():
        paths.extend(list(p.rglob("*.yml")))
        paths.extend(list(p.rglob("*.yaml")))

if not paths:
    print("No YAML files found.")
    sys.exit(0)

failed = False
for path in sorted(paths):
    try:
        with path.open("r", encoding="utf-8") as f:
            list(yaml.safe_load_all(f))
        print(f"OK: {path}")
    except Exception as e:
        failed = True
        print(f"FAIL: {path}: {e}")

if failed:
    sys.exit(1)
PY
else
  echo "python3 not available; skipping YAML parse check." | tee -a "$REPORT"
fi

section "17. Optional Ansible syntax check"

if command -v ansible-playbook >/dev/null 2>&1; then
  if [ -f "ansible/playbooks/site.yml" ]; then
    echo "+ ansible-playbook --syntax-check ansible/playbooks/site.yml" | tee -a "$REPORT"
    ansible-playbook --syntax-check ansible/playbooks/site.yml 2>&1 | tee -a "$REPORT" || true
  fi

  if [ -f "ansible/playbooks/verify.yml" ]; then
    echo "+ ansible-playbook --syntax-check ansible/playbooks/verify.yml" | tee -a "$REPORT"
    ansible-playbook --syntax-check ansible/playbooks/verify.yml 2>&1 | tee -a "$REPORT" || true
  fi
else
  echo "ansible-playbook not available; skipping Ansible syntax check." | tee -a "$REPORT"
fi

section "18. Optional Terraform formatting and validation"

if command -v terraform >/dev/null 2>&1 && [ -d "terraform" ]; then
  echo "+ terraform -chdir=terraform fmt -check -recursive" | tee -a "$REPORT"
  terraform -chdir=terraform fmt -check -recursive 2>&1 | tee -a "$REPORT" || true

  echo | tee -a "$REPORT"
  echo "Terraform validate requires initialized providers. Running only if .terraform exists." | tee -a "$REPORT"

  if [ -d "terraform/.terraform" ]; then
    echo "+ terraform -chdir=terraform validate" | tee -a "$REPORT"
    terraform -chdir=terraform validate 2>&1 | tee -a "$REPORT" || true
  else
    echo "terraform/.terraform not found; skipping terraform validate." | tee -a "$REPORT"
  fi
else
  echo "terraform not available or terraform/ missing; skipping Terraform checks." | tee -a "$REPORT"
fi

section "19. Summary and manual review hints"

cat <<'EOF' | tee -a "$REPORT"
Review the report for:

[Critical]
- Any real token/secret/key material committed.
- Any use of --privileged, host networking, host PID/IPC, or Docker socket mounts.
- Any host port binding to 0.0.0.0 for Hermes service ports.
- Any Tailscale auth task missing no_log: true.
- Any non-digest Hermes image when allow_unpinned_image is false.
- Any wildcard CORS setting.

[Important]
- Quadlet files should be under /home/hermes/.config/containers/systemd/.
- /home/hermes/.hermes should be 0700.
- /home/hermes/.hermes/.env should be 0600.
- API_SERVER_KEY should be generated once and never overwritten.
- verify.yml should fail closed.
- backup encryption should require backup_age_recipient when enabled.
- README should not claim encrypted backups if encryption is optional.

[Expected benign matches]
- Documentation may mention dangerous flags as examples of what NOT to do.
- API_SERVER_HOST=0.0.0.0 is acceptable inside the container if host port binding is 127.0.0.1.
- Variable names containing token/secret are acceptable if no real values are present.
EOF

echo
echo "Done. Full report written to: $REPORT"
