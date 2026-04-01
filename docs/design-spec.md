# Server Bootstrap Skills — Design Spec

三个独立 skill，用于新服务器的标准化初始化。可单独运行，也可组合使用。
由 Claude Code 执行，用户只需提供参数。

**仓库**：`github.com/bytsm54/server-bootstrap`（private）

---

## 前置条件（用户手动完成）

```bash
curl -fsSL https://claude.ai/install.sh | bash
claude   # 登录认证
```

之后用户只需告诉 Claude Code：
> Clone bytsm54/server-bootstrap 仓库，按 server-init 初始化服务器，然后安装所有 skills 并执行

Claude Code 分三阶段自动完成：

```
Phase 1 — Server Init（此时无 Node.js）:
  1. git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
  2. 直接读取并执行 skills/server-init/SKILL.md
     → hostname、timezone、Node.js、zsh 配置完成

Phase 2 — 安装 Skills（Node.js 已可用）:
  3. npx skills add bytsm54/server-bootstrap@server-init -g -y
  4. npx skills add bytsm54/server-bootstrap@ssh-hardening -g -y
  5. npx skills add bytsm54/server-bootstrap@claude-code-setup -g -y

Phase 3 — 执行剩余 skills:
  6. /ssh-hardening ssh_port=22022 allow_users=ubuntu
  7. /claude-code-setup github_username=bytsm54 github_email=bytsm54@gmail.com
```

---

## 1. `server-init` — 服务器初始化

### 目的

设置主机名、时区、安装 Node.js 运行时、配置 zsh 为默认 shell。

### 用户输入

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `hostname` | 是 | — | 主机名 |
| `timezone` | 否 | `Asia/Shanghai` | 系统时区 |
| `node_version` | 否 | `lts` | Node.js 版本，通过 NodeSource 安装 |
| `username` | 否 | `ubuntu` | 主用户名（用于 zsh 配置） |

### 执行步骤

1. **设置主机名**
   - `hostnamectl set-hostname <hostname>`
   - 更新 `/etc/hosts`：将旧主机名替换为新主机名
   - 注意：hostnamectl 强制 RFC 合规（不允许下划线），如需下划线则直接写 `/etc/hostname`

2. **设置时区和 locale**
   - `timedatectl set-timezone <timezone>`
   - 确保 `en_US.UTF-8` 和 `zh_CN.UTF-8` locale 已生成

3. **安装 Node.js / npm / npx**
   - 通过 NodeSource 安装指定版本的 Node.js
   - 验证 `node --version`、`npm --version`、`npx --version`

4. **配置 zsh**
   - 安装 zsh：`apt install -y zsh`
   - 将默认 shell 切换为 zsh：`chsh -s $(which zsh) <username>`
   - 配置 `~/.zshrc`：
     - **路径显示优化**：prompt 中显示完整路径或缩略路径
     - **Git 集成**：显示当前分支名、dirty/clean 状态、ahead/behind 计数
     - **基础优化**：命令历史、自动补全、语法高亮（如可用）
   - 不安装 oh-my-zsh 等重型框架，用原生 zsh 配置保持轻量

5. **验证**
   - 输出 hostname、timezone、node/npm 版本、当前 shell 确认

### 不做的事

- 不安装基础包（apt 工具包）— 按需手动装
- 不配置 SSH（由 `ssh-hardening` 负责）
- 不安装 Claude Code（用户手动完成）
- 不配置防火墙

---

## 2. `ssh-hardening` — SSH 安全加固

### 目的

一键完成 SSH 安全加固，兼容 VS Code Remote SSH / Cursor 等 IDE 远程开发。

### 用户输入

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `ssh_port` | 是 | — | SSH 端口号（如 `22022`） |
| `allow_users` | 是 | — | 允许 SSH 登录的用户列表（如 `ubuntu`） |
| `ide_compatible` | 否 | `true` | 是否兼容 IDE Remote SSH（影响 forwarding 和 keepalive） |
| `fail2ban_bantime` | 否 | `3600` | fail2ban 封禁时长（秒） |
| `fail2ban_maxretry` | 否 | `3` | fail2ban 最大重试次数 |

### 执行步骤

1. **写入 SSH 加固配置**
   - 备份已有配置：`cp /etc/ssh/sshd_config.d/*.conf /tmp/sshd_backup/`
   - 目标文件：`/etc/ssh/sshd_config.d/99-hardening.conf`
   - 配置内容：

   ```
   # SSH Hardening Configuration
   Port <ssh_port>

   # --- Authentication ---
   PermitRootLogin no
   PasswordAuthentication no
   PermitEmptyPasswords no
   KbdInteractiveAuthentication no
   PubkeyAuthentication yes
   MaxAuthTries 3
   MaxSessions 5
   LoginGraceTime 30
   AllowUsers <allow_users>

   # --- Keep-alive (IDE Remote SSH compatible) ---
   ClientAliveInterval 60
   ClientAliveCountMax 3
   TCPKeepAlive yes

   # --- Forwarding ---
   # ide_compatible=true:
   AllowTcpForwarding yes
   AllowStreamLocalForwarding yes
   AllowAgentForwarding yes
   # ide_compatible=false: 全部设为 no
   X11Forwarding no
   GatewayPorts no

   # --- Strong ciphers ---
   Ciphers aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr
   MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
   KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521

   # --- Security ---
   UseDNS no
   LogLevel VERBOSE
   ```

2. **验证 sshd 配置语法**
   - `sshd -t` 检查配置是否合法
   - 如果失败，回滚配置文件并报错，不继续后续步骤

3. **配置 fail2ban**
   - 安装 fail2ban（如未安装）
   - 写入 `/etc/fail2ban/jail.local`：
     ```
     [sshd]
     enabled = true
     port = <ssh_port>
     maxretry = <fail2ban_maxretry>
     bantime = <fail2ban_bantime>
     findtime = 600
     ```
   - 重启 fail2ban 服务

4. **重启 sshd**
   - `systemctl restart sshd`
   - 验证 sshd 正在监听新端口

5. **安全提醒**
   - 提醒用户在防火墙/安全组中开放新端口
   - 提醒用户在断开前用新端口测试连接

### 安全保障

- 写入配置前先备份原文件
- `sshd -t` 不通过则自动回滚，不重启
- 不会中断当前 SSH 连接（sshd restart 不影响已建立的连接）

---

## 3. `claude-code-setup` — Claude Code 环境配置

### 目的

在已安装 Claude Code 的服务器上，一键配置 plugins、skills、settings、GitHub 认证。

### 前置条件

- Node.js + npm 已安装（由 `server-init` 完成）
- Claude Code CLI 已安装并完成登录（用户手动完成）
- 有网络访问 GitHub 的能力

### 用户输入

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `github_username` | 是 | — | GitHub 用户名（用于 git config 和认证） |
| `github_email` | 是 | — | GitHub 邮箱（用于 git config） |
| `extra_plugins` | 否 | `[]` | 除默认清单外额外安装的 plugins |
| `extra_skills` | 否 | `[]` | 除默认清单外额外安装的 skills |
| `skip_plugins` | 否 | `[]` | 从默认清单中跳过的 plugins |
| `skip_skills` | 否 | `[]` | 从默认清单中跳过的 skills |

### 执行步骤

1. **配置 Git 身份**
   - `git config --global user.name <github_username>`
   - `git config --global user.email <github_email>`

2. **配置 GitHub 认证**
   - 检查 `GITHUB_TOKEN` 环境变量是否存在
   - 如不存在，引导用户：
     1. 前往 https://github.com/settings/tokens?type=beta 创建 Fine-grained PAT
     2. 权限：Administration (R/W)、Contents (R/W)
     3. 在 Claude Code 中执行 `! export GITHUB_TOKEN=<token>`
   - 验证 token 有效：`curl -s -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user`
   - 配置 git credential：使 GITHUB_TOKEN 用于 HTTPS clone/push

3. **安装 GitHub CLI**
   - 安装 `gh`（如未安装）
   - 使用 GITHUB_TOKEN 认证：`gh auth login --with-token`

4. **安装 Plugins（5个）**

   | Plugin | 来源 |
   |--------|------|
   | `superpowers` | github: `anthropics/claude-code-plugins` |
   | `claude-mem` | github: `thedotmack/claude-mem` |
   | `web-access` | git: `https://github.com/eze-is/web-access.git` |
   | `pua` | github: `tanweai/pua` |
   | `claude-hud` | github: `jarrodwatts/claude-hud` |

   - 逐个通过 `claude plugins install` 安装
   - 每个安装后验证是否出现在 `installed_plugins.json`
   - `settings.json` 由安装命令自动更新，无需手动写入

5. **安装自定义 Skills（10个）**

   | Skill | 来源 (GitHub) | 安装命令 |
   |-------|---------------|---------|
   | `context7` | `intellectronica/agent-skills` | `npx skills add intellectronica/agent-skills@context7 -g -y` |
   | `docx` | `anthropics/skills` (document-skills) | `npx skills add anthropics/skills@docx -g -y` |
   | `find-skills` | `vercel-labs/skills` | `npx skills add vercel-labs/skills@find-skills -g -y` |
   | `frontend-design` | `anthropics/skills` (example-skills) | `npx skills add anthropics/skills@frontend-design -g -y` |
   | `pdf` | `anthropics/skills` (document-skills) | `npx skills add anthropics/skills@pdf -g -y` |
   | `pptx` | `anthropics/skills` (document-skills) | `npx skills add anthropics/skills@pptx -g -y` |
   | `skill-creator` | `anthropics/skills` (example-skills) | `npx skills add anthropics/skills@skill-creator -g -y` |
   | `skill-vetter` | `useai-pro/openclaw-skills-security` | `npx skills add useai-pro/openclaw-skills-security@skill-vetter -g -y` |
   | `wechat-article-extractor` | `freestylefly/wechat-article-extractor-skill` | `npx skills add freestylefly/wechat-article-extractor-skill -g -y` |
   | `xlsx` | `anthropics/skills` (document-skills) | `npx skills add anthropics/skills@xlsx -g -y` |

   - 每个安装后验证 symlink 出现在 `~/.claude/skills/`
   - `.skill-lock.json` 由安装命令自动维护

6. **配置项目 memory**
   - 创建 `~/.claude/projects/` 基础结构
   - 写入标准 `feedback_skill_vetting.md`（skill 安装前必须 vetting）
   - 写入 `MEMORY.md` 模板

7. **验证**
   - 检查 plugins 数量 = 5（或 5 + extra - skip）
   - 检查 skills 数量 = 10（或 10 + extra - skip）
   - 验证 `gh auth status` 正常
   - 验证 `git config` 正确

---

## 仓库结构

```
server-bootstrap/                    # github.com/bytsm54/server-bootstrap (private)
├── README.md
├── skills/
│   ├── server-init/
│   │   └── SKILL.md
│   ├── ssh-hardening/
│   │   └── SKILL.md
│   └── claude-code-setup/
│       └── SKILL.md
└── templates/
    └── feedback_skill_vetting.md    # 标准 memory 文件
```

### 使用流程

```
新服务器
  │
  ├── 用户手动:
  │    curl -fsSL https://claude.ai/install.sh | bash
  │    claude  (登录认证)
  │
  └── 用户对 Claude Code 说:
       "Clone bytsm54/server-bootstrap，按 server-init 初始化，然后安装所有 skills 并执行"
       │
       └── Claude Code 自动完成:
            Phase 1 — 初始化（无 Node.js）:
              1. git clone ~/server-bootstrap
              2. 直接读取并执行 server-init/SKILL.md → 装好 Node.js
            Phase 2 — 安装 Skills（Node.js 已可用）:
              3. npx skills add bytsm54/server-bootstrap@server-init -g -y
              4. npx skills add bytsm54/server-bootstrap@ssh-hardening -g -y
              5. npx skills add bytsm54/server-bootstrap@claude-code-setup -g -y
            Phase 3 — 执行剩余 skills:
              6. /ssh-hardening ssh_port=22022 allow_users=ubuntu
              7. /claude-code-setup github_username=bytsm54 github_email=bytsm54@gmail.com
```
