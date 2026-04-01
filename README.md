# server-bootstrap

Three Claude Code skills for standardized server initialization.

## Skills

| Skill | Purpose |
|-------|---------|
| `server-init` | Set hostname, timezone, install Node.js, configure zsh |
| `ssh-hardening` | SSH security hardening with IDE compatibility |
| `claude-code-setup` | Install plugins, skills, configure GitHub auth |

## Usage

### Prerequisites (manual)

```bash
# 1. Install Claude Code
curl -fsSL https://claude.ai/install.sh | bash

# 2. Login
claude
```

### Run

Tell Claude Code:

> Clone bytsm54/server-bootstrap 仓库，按 server-init 初始化服务器，然后安装所有 skills 并执行

Claude Code will:

```
Phase 1 — Server Init (Node.js not yet available):
  1. git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
  2. Read and execute skills/server-init/SKILL.md directly
     → hostname, timezone, Node.js, zsh configured

Phase 2 — Install Skills (Node.js now available):
  3. npx skills add bytsm54/server-bootstrap@server-init -g -y
  4. npx skills add bytsm54/server-bootstrap@ssh-hardening -g -y
  5. npx skills add bytsm54/server-bootstrap@claude-code-setup -g -y

Phase 3 — Execute remaining skills:
  6. /ssh-hardening ssh_port=22022 allow_users=ubuntu
  7. /claude-code-setup github_username=bytsm54 github_email=bytsm54@gmail.com
```
