# server-bootstrap

Three Claude Code skills for standardized server initialization, plus a top-level orchestrator.

## Skills

| Skill | Purpose |
|-------|---------|
| `server-bootstrap` | Orchestrator — runs all three skills in correct order |
| `server-init` | Set hostname, timezone, install Node.js, configure zsh |
| `ssh-hardening` | SSH security hardening with IDE compatibility |
| `claude-code-setup` | Install plugins, skills, configure GitHub auth |

## Usage

### Prerequisites (manual)

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude   # login
```

### Run

Tell Claude Code:

> Clone bytsm54/server-bootstrap 仓库，执行服务器初始化

Claude Code reads the top-level `SKILL.md`, automatically handles the three-phase execution order, and asks you for the required parameters.
