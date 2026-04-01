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

## Execution Order

### Phase 1 — Server Init (no Node.js yet)

Node.js is not available at this point, so skills cannot be formally installed via `npx skills add`.

1. Clone the repo:
   ```bash
   git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
   ```
2. Read `skills/server-init/SKILL.md` from the local clone
3. Execute it with the user's parameters — this installs Node.js, sets hostname, timezone, and configures zsh
4. Verify Node.js is available: `node --version && npm --version && npx --version`

### Phase 2 — Install Skills (Node.js now available)

Now that npm/npx work, formally install all three skills so they are registered in Claude Code:

```bash
npx skills add bytsm54/server-bootstrap@server-init -g -y
npx skills add bytsm54/server-bootstrap@ssh-hardening -g -y
npx skills add bytsm54/server-bootstrap@claude-code-setup -g -y
```

Verify: `ls ~/.claude/skills/` shows all three.

### Phase 3 — Execute remaining skills

1. Execute `/ssh-hardening` with the user's SSH parameters
2. Execute `/claude-code-setup` with the user's GitHub parameters

## Done

Print a final summary of everything that was configured:
- Hostname, timezone, Node.js version, shell
- SSH port, allowed users, fail2ban status
- GitHub auth, plugins count, skills count
