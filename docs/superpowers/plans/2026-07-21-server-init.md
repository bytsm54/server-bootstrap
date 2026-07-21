# Pure Server Initialization Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add a repository-local shell entry that initializes Ubuntu or Debian without configuring AI development tools.

**Architecture:** scripts/server-init.sh will validate configuration and orchestrate existing phase scripts. scripts/verify-server.sh will report only server state. Existing phases remain the implementation source of truth; Node gains an optional Bun switch and SSH rollback gains deadman cancellation.

**Tech Stack:** Bash, existing phase scripts, isolated tests with temporary fake commands and stub phases.

## Global Constraints

- Reuse phases 01, 02, 02a, 02b, 03, 05, 08, and 09.
- Never invoke phases 04, 04a, 04b, 06, 07, or 07a.
- Keep scripts/bootstrap.sh behavior unchanged.
- Keep scripts/03-node.sh Bun default at yes; server-init.sh passes no by default.
- SSH and fail2ban default to enabled; SSH requires an explicit 已准备 response.
- Tests require no root, sudo access, network access, or host modification.
- Stop immediately when an invoked phase returns nonzero.

---

### Task 1: Make Bun Optional in the Node Phase

**Files:**
- Create: tests/node-bun-option.sh
- Modify: scripts/03-node.sh

**Interfaces:**
- Consumes: existing --node-version and --npm-registry options.
- Produces: --install-bun yes|no; omitted means yes.

- [ ] **Step 1: Write the failing Bun option test**

Create a temporary HOME with fake nvm.sh, node, npm, npx, and curl commands. Fake curl emits a Bun installer only for bun.sh/install. Assert:

~~~bash
bash scripts/03-node.sh --node-version lts --npm-registry official --install-bun no
test ! -e "$HOME/bun-installed"
! grep -q 'server-bootstrap:bun-path' "$HOME/.bashrc"

bash scripts/03-node.sh --node-version lts --npm-registry official --install-bun yes
test -x "$HOME/.bun/bin/bun"
test -e "$HOME/bun-installed"
grep -q 'server-bootstrap:bun-path' "$HOME/.bashrc"
~~~

The fake nvm function handles ls, use, and alias. Fake npm handles version, prefix, and config operations.

- [ ] **Step 2: Run the test and verify RED**

Run: rtk proxy bash tests/node-bun-option.sh

Expected: nonzero because --install-bun is unknown.

- [ ] **Step 3: Implement the minimal option**

Add:

~~~bash
INSTALL_BUN="yes"

--install-bun) INSTALL_BUN="$2"; shift 2 ;;

case "$INSTALL_BUN" in
  yes|no) ;;
  *) err "--install-bun 必须是 yes 或 no"; exit 2 ;;
esac
~~~

Wrap Bun installation in an INSTALL_BUN=yes branch. Export INSTALL_BUN before the Python PATH editor. Include the Bun SPECS entry only when INSTALL_BUN is yes; always retain nvm-load and localbin-path.

- [ ] **Step 4: Run focused verification**

~~~bash
rtk proxy bash tests/node-bun-option.sh
rtk proxy bash tests/toolchain-paths.sh
rtk proxy bash -n scripts/03-node.sh tests/node-bun-option.sh
~~~

Expected: both tests print pass messages and syntax exits 0.

- [ ] **Step 5: Commit**

~~~bash
git add scripts/03-node.sh tests/node-bun-option.sh
git commit -m "feat: make bun optional in node phase"
~~~

---

### Task 2: Cancel the Deadman During Manual SSH Rollback

**Files:**
- Create: tests/ssh-deadman-cancel.sh
- Modify: scripts/08-ssh-harden.sh

**Interfaces:**
- Consumes: rollback and rollback --auto modes.
- Produces: manual rollback cancels its queued at job; automatic rollback does not cancel itself.

- [ ] **Step 1: Write the failing rollback regression test**

Put fake id and sudo commands first in PATH. Fake id -u returns a non-root UID. Fake sudo logs delegated commands, returns a backup path for backup lookup, returns job ID 42 for the deadman record, and succeeds for tar, sshd, systemctl, rm, and atrm.

Assert:

~~~bash
grep -q '^atrm 42$' "$MANUAL_LOG"
if grep -q '^atrm 42$' "$AUTO_LOG"; then
  echo "FAIL: automatic rollback cancelled its own job" >&2
  exit 1
fi
~~~

- [ ] **Step 2: Run the test and verify RED**

Run: rtk proxy bash tests/ssh-deadman-cancel.sh

Expected: nonzero because manual rollback does not call atrm.

- [ ] **Step 3: Implement cancellation**

Before restoring the backup in manual rollback, read the job ID from DEADMAN_FILE and call atrm. Guard the block with AUTO=0. Keep the existing final record removal.

Exact behavior:

~~~bash
if [ "$AUTO" -eq 0 ] && deadman_record_exists; then
  JOB_ID="$(read_deadman_job_id)"
  [ -z "$JOB_ID" ] || cancel_deadman_job "$JOB_ID"
fi
~~~

Implement the three named helpers using the existing SUDO array so both root and non-root execution work. Automatic rollback must skip the block.

- [ ] **Step 4: Run focused verification**

~~~bash
rtk proxy bash tests/ssh-deadman-cancel.sh
rtk proxy bash -n scripts/08-ssh-harden.sh tests/ssh-deadman-cancel.sh
~~~

Expected: ssh deadman cancellation tests passed; syntax exits 0.

- [ ] **Step 5: Commit**

~~~bash
git add scripts/08-ssh-harden.sh tests/ssh-deadman-cancel.sh
git commit -m "fix: cancel deadman on manual ssh rollback"
~~~


---

### Task 3: Add the Pure Server Orchestrator

**Files:**
- Create: scripts/server-init.sh
- Create: tests/server-init.sh

**Interfaces:**
- Consumes: every CLI option in the approved design plus REPO_DIR.
- Produces: normalized calls to phases 01, 02, 02a, 02b, 03, 05, 08, 09, and verify-server.sh.

- [ ] **Step 1: Write failing orchestration tests**

Create a temporary REPO_DIR/scripts tree. Each stub appends its filename and arguments to CALL_LOG. The SSH stub accepts apply, confirm, and rollback. Set SERVER_INIT_INTERACTIVE=yes so piped answers simulate a terminal.

For a confirmed default run, assert:

~~~text
01-preflight.sh
02-base-deps.sh
02a-system.sh --timezone Asia/Shanghai
02b-zsh.sh --theme powerlevel10k/powerlevel10k
03-node.sh --node-version lts --npm-registry official --install-bun no
05-git-identity.sh --name Test User --email test@example.com
08-ssh-harden.sh apply --port 22022 --allow-users tester --permit-root no --password-auth no --rollback-after-minutes 5
08-ssh-harden.sh confirm
09-fail2ban.sh --ssh-port 22022
verify-server.sh
~~~

Add cases for --help, invalid yes/no, missing Git identity without interactivity, Bun enabled, SSH disabled, SSH safety-gate skip, SSH failure/rollback, and a phase returning nonzero. Assert no call contains 04, 04a, 04b, 06, 07, or 07a.

- [ ] **Step 2: Run the test and verify RED**

Run: rtk proxy bash tests/server-init.sh

Expected: nonzero because scripts/server-init.sh does not exist.

- [ ] **Step 3: Implement parsing and validation**

Normalize the approved defaults. Track which options were supplied so only missing values are prompted. Git name and email are mandatory.

~~~bash
valid_yes_no() { case "$1" in yes|no) return 0 ;; *) return 1 ;; esac; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ] && [ "$1" -ne 22 ]; }
valid_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; }
~~~

Production interactivity uses -t 0. Tests may set SERVER_INIT_INTERACTIVE=yes. Missing Git identity without interactivity exits 2 before changes. Default ssh_allow_users comes from whoami and empty output is fatal.

- [ ] **Step 4: Implement summary confirmation and phase execution**

Print all normalized values. Accept y, yes, 是, or 确认 for the overall gate; other answers exit 0 before phases.

~~~bash
run_phase() {
  local label="$1"
  shift
  log "$label"
  "$@" || { err "$label 失败，停止初始化"; return 1; }
}
~~~

Check all required phase files before phase 01. Use REPO_DIR when supplied; otherwise infer the root from server-init.sh.

- [ ] **Step 5: Implement SSH result routing**

Require 已准备 at the SSH gate. Other input skips SSH and leaves fail2ban on port 22. After apply, use read -r -t with the rollback minutes converted to seconds.

- 成功 calls confirm and selects the new port.
- 失败, timeout, or other input calls rollback and selects port 22.
- apply failure stops the flow before fail2ban.

- [ ] **Step 6: Run focused verification**

~~~bash
rtk proxy bash tests/server-init.sh
rtk proxy bash -n scripts/server-init.sh tests/server-init.sh
~~~

Expected: server init orchestration tests passed; syntax exits 0.

- [ ] **Step 7: Commit**

~~~bash
git add scripts/server-init.sh tests/server-init.sh
git commit -m "feat: add pure server initialization entry"
~~~

---

### Task 4: Add Server-Only Verification and Documentation

**Files:**
- Create: scripts/verify-server.sh
- Create: tests/verify-server.sh
- Modify: README.md
- Modify: tests/server-init.sh

**Interfaces:**
- Consumes: state produced by the pure server phases.
- Produces: a report with no Claude, Codex, RTK, plugin, skill, project, or memories checks.

- [ ] **Step 1: Write the failing verifier test**

Run the verifier with a temporary HOME and fake node, npm, npx, git, hostnamectl, timedatectl, zsh, getent, ss, sudo, systemctl, and fail2ban-client.

Assert output contains Node, npm, git, zsh, sshd, and fail2ban. Reject excluded output:

~~~bash
for excluded in "Claude Code" "Codex" "RTK" "Plugins" "Skills" "memories"; do
  if grep -Fq "$excluded" "$OUTPUT"; then
    echo "FAIL: verifier contains excluded AI check: $excluded" >&2
    exit 1
  fi
done
~~~

- [ ] **Step 2: Run the test and verify RED**

Run: rtk proxy bash tests/verify-server.sh

Expected: nonzero because scripts/verify-server.sh does not exist.

- [ ] **Step 3: Implement the server-only verifier**

Build the verifier in this exact order: source scripts/lib/toolchain.sh; print hostname and timezone; source nvm.sh when present; append ~/.local/bin; report Node and npm; run the existing node/npm/npx ownership loop; report Bun only when executable; read Git name, email, and init.defaultBranch; report zsh/default shell/theme; inspect ss output for sshd ports; warn when /var/run/sshd-bootstrap-deadman.atjob exists; then report fail2ban service and jail state when fail2ban-client exists.

~~~bash
ok()   { printf '  ✅ %s\n' "$*"; }
miss() { printf '  ❌ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }
~~~

Do not copy Claude, Codex, RTK, plugin, skill, project, or memories blocks.

Use these exact failure rules: missing Node, npm, or Git identity prints ❌; absent Bun, zsh, sshd port visibility, or fail2ban prints nothing and is not a failure; a present but inactive fail2ban service prints ⚠️.

- [ ] **Step 4: Update README**

Add:

~~~bash
git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
bash ~/server-bootstrap/scripts/server-init.sh
~~~

Add one fully parameterized example and state that this entry never runs phases 04, 04a, 04b, 06, 07, or 07a.

- [ ] **Step 5: Run focused and full verification**

~~~bash
rtk proxy bash tests/verify-server.sh
rtk proxy bash tests/server-init.sh
rtk proxy bash tests/node-bun-option.sh
rtk proxy bash tests/ssh-deadman-cancel.sh
rtk proxy bash tests/toolchain-paths.sh
rtk proxy bash -n scripts/*.sh scripts/lib/*.sh tests/*.sh
rtk git diff --check
~~~

Expected: all five tests print pass messages; syntax and diff checks exit 0.

- [ ] **Step 6: Commit**

~~~bash
git add scripts/verify-server.sh tests/verify-server.sh tests/server-init.sh README.md
git commit -m "docs: add pure server initialization workflow"
~~~

---

### Task 5: Final Requirement Audit

**Files:**
- Review: docs/superpowers/specs/2026-07-21-server-init-design.md
- Review: all files changed in Tasks 1-4.

**Interfaces:**
- Consumes: completed implementation and fresh test output.
- Produces: evidence that all approved requirements are implemented.

- [ ] **Step 1: Confirm excluded phase references are absent**

Run:

~~~bash
rtk grep -n "04-claude|04a-codex|04b-rtk|06-project|07-plugins|07a-codex" scripts/server-init.sh
~~~

Expected: no matches.

- [ ] **Step 2: Confirm existing bootstrap compatibility**

Run:

~~~bash
rtk grep -n "03-node.sh" scripts/bootstrap.sh SKILL.md
~~~

Expected: existing callers omit --install-bun and retain the yes default.

- [ ] **Step 3: Run final verification**

~~~bash
rtk proxy bash -n scripts/*.sh scripts/lib/*.sh tests/*.sh
rtk proxy bash tests/node-bun-option.sh
rtk proxy bash tests/ssh-deadman-cancel.sh
rtk proxy bash tests/server-init.sh
rtk proxy bash tests/verify-server.sh
rtk proxy bash tests/toolchain-paths.sh
rtk git diff --check
rtk git status --short
~~~

Expected: syntax succeeds; all five tests pass; diff check succeeds; status contains only intentional plan or implementation files.
