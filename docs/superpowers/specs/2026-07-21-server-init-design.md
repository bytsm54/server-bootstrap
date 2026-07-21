# Pure Server Initialization Entry Design

## Goal

Add a repository-local shell entry point for initializing a fresh Ubuntu or Debian server without installing or configuring AI development tools.

The entry point will reuse the repository's existing phase scripts for system setup, Node.js, Git, SSH hardening, and fail2ban. It will not duplicate their implementation.

## Scope

The new flow includes:

- Debian/Ubuntu environment and network preflight checks.
- Base apt dependencies.
- Optional hostname and timezone configuration.
- Optional zsh, oh-my-zsh, plugins, and theme setup.
- nvm and Node.js setup.
- Optional Bun setup.
- Git global identity setup.
- Optional SSH hardening with explicit confirmation, backup, deadman rollback, and second-terminal verification.
- Optional fail2ban sshd jail setup.
- A server-only final verification report.

The new flow explicitly excludes:

- Claude Code, Codex CLI, and RTK installation or configuration.
- Codex memories or other Codex configuration.
- Project cloning and dependency installation.
- Claude plugins and skills installation.
- Claude-to-Codex skill sharing.
- Skill registration in Claude or Codex.

## Architecture

Create `scripts/server-init.sh` as a lightweight orchestrator. It owns argument parsing, interactive collection, configuration summary, validation, phase ordering, and the SSH confirmation flow. It delegates actual setup work to existing phase scripts.

Create `scripts/verify-server.sh` for the final report. It checks only the system capabilities managed by the pure server flow and does not inspect AI tools or their configuration.

The execution order is:

1. Validate and normalize all input.
2. Run `01-preflight.sh`.
3. Run `02-base-deps.sh`.
4. Run `02a-system.sh` when hostname or timezone is enabled.
5. Run `02b-zsh.sh` when zsh installation is enabled.
6. Run `03-node.sh` with the selected Node.js, npm registry, and Bun settings.
7. Run `05-git-identity.sh`.
8. Run the SSH hardening flow when enabled.
9. Run `09-fail2ban.sh` when enabled.
10. Run `verify-server.sh`.

The orchestrator must never invoke phases `04`, `04a`, `04b`, `06`, `07`, or `07a`.

## Command-Line Interface

`scripts/server-init.sh` accepts:

- `--hostname <name>`
- `--timezone <zone>`
- `--install-zsh yes|no`
- `--zsh-theme <theme>`
- `--node-version <lts-or-version>`
- `--npm-registry official|china`
- `--install-bun yes|no`
- `--git-name <name>`
- `--git-email <email>`
- `--harden-ssh yes|no`
- `--ssh-port <port>`
- `--ssh-allow-users <comma-separated-users>`
- `--ssh-permit-root yes|no`
- `--ssh-password-auth yes|no`
- `--ssh-rollback-minutes <positive-integer>`
- `--enable-fail2ban yes|no`
- `--help`

Command-line arguments take precedence. Missing values are collected interactively when standard input is a terminal. Git name and email are required and must be prompted for when absent. If a required value is absent and input is not interactive, the script exits before making changes.

Default values are:

- Hostname: unchanged.
- Timezone: `Asia/Shanghai`.
- zsh: enabled.
- zsh theme: `powerlevel10k/powerlevel10k`.
- Node.js: `lts`.
- npm registry: `official`.
- Bun: disabled, but shown as a choice during interactive collection.
- SSH hardening: enabled.
- SSH port: `22022`.
- SSH allowed users: the current user from `whoami`.
- SSH root login: disabled.
- SSH password authentication: disabled.
- SSH rollback window: five minutes.
- fail2ban: enabled.

Before running phases, the script prints the complete normalized configuration and requires one overall confirmation. Declining exits without making changes.

## Existing Phase Compatibility

Extend `scripts/03-node.sh` with `--install-bun yes|no`.

Its default remains `yes` so the behavior of the existing `bootstrap.sh` and Skill flow does not change. `server-init.sh` passes the user's normalized choice, whose default is `no`.

When Bun is disabled, `03-node.sh` must skip both Bun installation and Bun-specific PATH block management. It must continue to manage nvm and `~/.local/bin` PATH blocks for Node.js and general user-installed executables.

No AI-specific phase script is modified or invoked by the new entry point.

## SSH Safety Flow

SSH hardening remains a separate safety gate even after the overall configuration confirmation.

Before `apply`, the script prints the effective port, allowed users, root-login setting, password-authentication setting, rollback window, and cloud firewall reminder. It proceeds only after the user explicitly enters `已准备`. Any other response skips SSH hardening without changing sshd.

When SSH hardening is applied:

1. Call `08-ssh-harden.sh apply` with the normalized settings.
2. Stop on any nonzero exit code. Do not call `confirm` after an apply failure.
3. Ask the user to test the new port from a second terminal while keeping the original session open.
4. On `成功`, call `08-ssh-harden.sh confirm`.
5. On `失败`, call `08-ssh-harden.sh rollback`.
6. Wait for the response only for the configured rollback window. On input timeout, call `08-ssh-harden.sh rollback` immediately. The scheduled deadman remains the fallback if the orchestrator exits or disconnects before it can do so.

Update the existing manual rollback path to cancel its pending `at` job before removing the deadman record. The `rollback --auto` path must not attempt to cancel the job that is currently executing. This prevents a manual failure or timeout rollback from being repeated later by the queued deadman.

fail2ban uses the new SSH port only after successful SSH confirmation. If SSH hardening is disabled, skipped at the safety gate, or rolled back, fail2ban uses port `22`. If SSH `apply` itself returns nonzero, the orchestrator stops immediately and does not configure fail2ban.

## Error Handling

All argument formats are validated before any phase changes the system. Validation covers yes/no fields, npm registry, SSH port range, rollback duration, required Git identity, and current-user discovery.

Each phase is executed through a small logging wrapper. A nonzero exit code stops the orchestrator immediately and reports the failed phase. Later phases are not attempted.

The script resolves the repository root from its own location by default and supports the existing `REPO_DIR` override. It checks for every required phase script before starting. A missing dependency is reported as an error instead of being downloaded or silently replaced.

The new flow does not reset, stash, or overwrite repository changes.

## Server-Only Verification

`scripts/verify-server.sh` reports:

- Hostname and timezone.
- Node.js, npm, their active paths, npm prefix, and registry.
- Whether nvm owns `node`, `npm`, and `npx` without conflicting `~/.local/bin` shims.
- Bun only when installed; absence is not a failure.
- Git global name, email, and default branch.
- zsh installation, default-shell status, and configured theme when present.
- Active sshd listening ports when observable.
- Pending SSH deadman state.
- fail2ban service and sshd jail state when installed.

It does not check Claude Code, Codex, RTK, plugins, skills, Codex memories, projects, or AI configuration files.

## Documentation

Update `README.md` with a pure-server initialization section showing:

```bash
git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
bash ~/server-bootstrap/scripts/server-init.sh
```

Also include a representative fully parameterized invocation and clearly distinguish this entry from the existing AI-oriented `bootstrap.sh` and `SKILL.md` flow.

## Tests

Add shell tests that use a temporary `REPO_DIR` populated with stub phase scripts so no packages, shell settings, SSH configuration, or services are changed.

Tests cover:

- `--help` exits successfully.
- Default normalization and command-line overrides.
- Invalid arguments fail before any phase executes.
- Required Git identity behavior for noninteractive input.
- Phase order.
- Excluded AI and project phases are never invoked.
- Bun enabled and disabled routing into `03-node.sh`.
- A failed phase prevents later phases from running.
- SSH-disabled and SSH-skipped flows send fail2ban port `22`.
- Successfully confirmed SSH sends the configured new port to fail2ban.
- SSH failure triggers rollback and does not use the new port.
- Manual SSH rollback cancels the queued deadman job, while automatic rollback does not cancel itself.
- All repository shell scripts pass `bash -n`.
- Existing toolchain path tests continue to pass.

The tests must not require root or sudo.

## Success Criteria

- A user can clone the repository on a fresh Ubuntu or Debian server and run one repository-local script to complete non-AI server initialization.
- The entry supports command-line overrides and prompts for missing values.
- Node.js is installed through nvm, while Bun is optional and disabled by default for this entry.
- SSH and fail2ban are selected by default, with SSH still protected by an explicit safety gate and deadman rollback.
- No Claude, Codex, RTK, project, plugin, or skill setup is executed or verified.
- Existing `bootstrap.sh` behavior remains unchanged.
- Automated tests exercise orchestration without modifying the host system.
