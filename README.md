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

1. Install Node.js + npm
2. `npm install -g @anthropic-ai/claude-code`
3. Run `claude` and complete login

### Run

Tell Claude Code:

> 安装 bytsm54/server-bootstrap 的 skills，然后执行服务器初始化

Claude Code will:

```bash
npx skills add bytsm54/server-bootstrap@server-init -g -y
npx skills add bytsm54/server-bootstrap@ssh-hardening -g -y
npx skills add bytsm54/server-bootstrap@claude-code-setup -g -y
```

Then invoke each skill:

```
/server-init hostname=myserver
/ssh-hardening ssh_port=22022 allow_users=ubuntu
/claude-code-setup github_username=bytsm54 github_email=bytsm54@gmail.com
```
