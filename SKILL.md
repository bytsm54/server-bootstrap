---
name: server-bootstrap
description: Full server bootstrap — initialize server (hostname, timezone, Node.js, zsh), harden SSH, and set up Claude Code environment (plugins, skills, GitHub auth) in one go. Use this skill when the user asks to bootstrap, initialize, or set up a new server, or says "server-bootstrap" or "初始化服务器".
---

# Server Bootstrap

Complete server initialization in three phases. This skill orchestrates `server-init`, `ssh-hardening`, and `claude-code-setup` in the correct order.

## Parameters

Collect all parameters upfront before starting:

**server-init:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `hostname` | yes | — | Server hostname |
| `timezone` | no | `Asia/Shanghai` | System timezone |
| `node_version` | no | `lts` | Node.js version |
| `username` | no | `ubuntu` | Primary user |
| `npm_registry` | no | `official` | `china` (npmmirror.com) or `official` (npmjs.org) |

**ssh-hardening:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ssh_port` | yes | — | SSH port number |
| `allow_users` | yes | — | Allowed SSH users |
| `ide_compatible` | no | `true` | IDE Remote SSH compatibility |

**claude-code-setup:**
| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `github_username` | yes | — | GitHub username |
| `github_email` | yes | — | GitHub email |

## Phase Dependencies

```
Phase 1 (server-init)      → produces: node, npm, npx, zsh, ~/.local/bin in PATH
Phase 2 (skill registration) → requires: npx (from Phase 1)
Phase 3a (ssh-hardening)   → requires: nothing (independent)
Phase 3b (claude-code-setup) → requires: node, claude CLI in PATH
Phase 3a and 3b are independent and can run in either order.
```

## Execution Order

### Phase 1 — Server Init (no Node.js yet)

Node.js is not available at this point, so skills cannot be formally installed via `npx skills add`.

1. Clone the repo (default `~/server-bootstrap`, or current directory if user specifies):
   ```bash
   REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"
   git clone https://github.com/bytsm54/server-bootstrap.git "$REPO_DIR"
   ```
   **All subsequent references to repo files use `$REPO_DIR`.** If the user cloned to a different path, set `REPO_DIR` accordingly.
2. Read `$REPO_DIR/skills/server-init/SKILL.md` from the local clone
3. Execute it with the user's parameters — this installs Node.js, sets hostname, timezone, and configures zsh
4. Verify Node.js is available: `node --version && npm --version && npx --version`

### Between Phase 1 and 2 — Verify PATH

After server-init completes, ensure all tools are accessible in the current shell:

```bash
# Load nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

# Ensure ~/.local/bin is in PATH (for claude CLI)
export PATH="$HOME/.local/bin:$PATH"

# Verify
node --version && npm --version && npx --version && claude --version
```

If any command fails, diagnose and fix before proceeding. Do not skip this step.

**IMPORTANT — nvm in Claude Code's Bash tool:** Claude Code spawns a fresh shell for every `Bash` tool call. The nvm loader from `.zshrc` is NOT automatically sourced because Bash tool uses `bash`, not `zsh -l`. For **every** subsequent Bash command that needs `node`, `npm`, or `npx`, you MUST prepend:

```bash
export NVM_DIR="$HOME/.nvm" && [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && <your command>
```

Alternatively, after Phase 1 completes and `.zshrc` is configured, you can run commands via login zsh which auto-sources nvm:

```bash
zsh -l -c "<your command>"
```

### Phase 2 — Register Skills in Claude Code (Node.js now available)

The skills CLI (`npx skills add`) only recognizes the root-level SKILL.md in a repo, not sub-directory skills. So we install the top-level skill, then symlink the three sub-skills.

1. Install the top-level skill:
   ```bash
   npx skills add bytsm54/server-bootstrap -g -y
   ```

2. Symlink sub-skills so Claude Code can invoke them individually:
   ```bash
   SKILL_SRC="$HOME/.agents/skills/server-bootstrap"
   ln -sf "$SKILL_SRC/skills/server-init" "$HOME/.claude/skills/server-init"
   ln -sf "$SKILL_SRC/skills/ssh-hardening" "$HOME/.claude/skills/ssh-hardening"
   ln -sf "$SKILL_SRC/skills/claude-code-setup" "$HOME/.claude/skills/claude-code-setup"
   ```

3. Verify:
   ```bash
   ls -la ~/.claude/skills/ | grep -E "server-init|ssh-hardening|claude-code-setup"
   ```

If any step fails, report the error and stop.

**Note on updates:** `npx skills update server-bootstrap` will pull the latest root skill, and because symlinks point into the installed skill directory, sub-skills update automatically — the symlinks follow the target. However, if a new sub-skill is **added** to a future version, the symlink for it must be created manually. To re-sync all sub-skills after an update:

```bash
SKILL_SRC="$HOME/.agents/skills/server-bootstrap"
for sub in "$SKILL_SRC"/skills/*/; do
  name=$(basename "$sub")
  ln -sf "$sub" "$HOME/.claude/skills/$name"
done
```

### Phase 3 — Execute remaining skills

1. Execute `/ssh-hardening` with the user's SSH parameters
2. Execute `/claude-code-setup` with the user's GitHub parameters

## Done

Print a final summary of everything that was configured:
- Hostname, timezone, Node.js version, shell
- SSH port, allowed users, fail2ban status
- GitHub auth, plugins count, skills count
