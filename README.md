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
# 1. Install Claude Code and login
curl -fsSL https://claude.ai/install.sh | bash
claude   # login

# 2. Set up GitHub token (required — this is a private repo)
# Create a Fine-grained PAT at https://github.com/settings/tokens?type=beta
# with Contents: Read permission, then:
echo 'export GITHUB_TOKEN=<your-token>' >> ~/.bashrc && source ~/.bashrc
```

### Run

Tell Claude Code:

> Clone bytsm54/server-bootstrap 仓库，执行服务器初始化

Claude Code reads the top-level `SKILL.md`, automatically handles the four-phase execution order (GitHub auth → server init → install skills → SSH + Claude Code setup), and asks you for the required parameters.
