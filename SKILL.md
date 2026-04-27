---
name: server-bootstrap
description: 在一台全新的 Ubuntu / Debian 服务器上完成"零到可用"的初始化——安装 Node.js (via nvm, 用户态)、Claude Code CLI、配置 git 身份, 可选地克隆项目仓库并安装语言依赖, 可选地安装 Claude Code plugins / skills (从可编辑的清单中由用户挑选)。Use this skill whenever the user asks to bootstrap, initialize, provision, or set up a fresh / new Ubuntu / Debian server, VPS, droplet, or dev box, including phrasing like "装机"、"新机配置"、"上线一台新服务器"、"从零配 Claude Code 环境"、"配 Node + Claude Code"、"server bootstrap"、"VPS init"。Also trigger when the user explicitly invokes phase scripts under `scripts/`.
---

# server-bootstrap

把一台全新的 Ubuntu / Debian 服务器变成「Claude Code 可用 + git 身份配好 + 项目可选就位」的可用环境。

**所有 Node / nvm / Claude Code 都装到用户态（`$HOME` 下），全程仅 `02-base-deps` 一个 phase 可能需要 sudo（且已装则跳过）。**

---

## Prerequisites（一次性手动）

本 skill 假设 **Claude Code 已经在目标服务器上运行**。如果是真·全新服务器，先 SSH 进去跑一行：

```bash
curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
```

`bootstrap.sh` 会装好 apt 基础依赖 + Node (via nvm) + Claude Code，然后打印下一步指引。完成后执行：

```bash
claude   # 登录
```

进入 claude 会话, 说：「执行 server-bootstrap」, 即触发本 skill 走完后续 phase（git 身份 / 可选项目 / 可选 plugin-skill）。

> 也支持「不用 SKILL, 只用 bootstrap.sh」最小路径——只装 Node + Claude Code, 其他都跳过。这是同一份脚本, 行为一致。

---

## 参数

第一次进入 skill 时, 一次性把下面的参数收齐再开始执行——不要中途反复打断用户。

### 必填

| 参数 | 说明 |
|---|---|
| `git_user_name` | git 全局 `user.name`, 用于 commit 署名 |
| `git_user_email` | git 全局 `user.email` |

### 可选（不填则该 phase 跳过 / 走默认）

| 参数 | 默认 | 说明 |
|---|---|---|
| `hostname` | （空, 跳过） | 设系统 hostname, 同步 /etc/hosts 127.0.1.1 行 |
| `timezone` | （空, 跳过） | 设时区, 如 `Asia/Shanghai`、`UTC`、`America/New_York` |
| `node_version` | `lts` | nvm install 的 Node 版本, 如 `lts`、`20`、`22.5.0` |
| `npm_registry` | `official` | `china` (npmmirror.com) 或 `official` (npmjs.org)。**中国大陆用户强烈建议设 `china`** |
| `claude_install_method` | `auto` | `auto`（github 失败回落 curl）/ `github`（GitHub releases 直下二进制, **国内推荐**, 走 github.com 不经 Cloudflare）/ `curl`（claude.ai/install.sh, 国内常 403）。**npm 方式已被 Anthropic 弃用, 本 skill 不再提供** |
| `claude_version` | （空）= latest | 显式钉版本如 `v2.1.119`, 跳过 GitHub API 查询（API 60 次/小时限流时有用） |
| `install_zsh` | `false` | true 时进入 phase 02b：装 zsh + oh-my-zsh + 设默认 shell |
| `zsh_theme` | `agnoster` | 仅 `install_zsh=true` 时生效, 任何 oh-my-zsh 内置主题名都行 |
| `project_repo_url` | （空, 跳过 phase 06） | 要克隆的项目 git URL |
| `project_dir` | `~/<repo basename>` | 克隆目标路径 |
| `project_env_keys` | （空） | 项目需要的环境变量 key 列表（如 `TUSHARE_TOKEN,OPENAI_API_KEY`）, phase 06 会**引导用户填到 `.env`**, 不写 `~/.zshrc` |
| `install_plugins_skills` | `false` | 是否进入 phase 07; true 时 agent 会展示 `templates/*.yaml` 让用户挑选 |
| `harden_ssh` | `false` | **高风险**, 是否进入 phase 08。下面参数仅 `harden_ssh=true` 时需要 |
| `ssh_port` | （必填若 harden_ssh） | 1024-65535, 不能是 22 |
| `ssh_allow_users` | （必填若 harden_ssh） | 逗号分隔, 如 `ubuntu,bytsm54` |
| `ssh_permit_root` | `no` | `no` 或 `yes` |
| `ssh_password_auth` | `no` | `no` 或 `yes`. 选 `no` 时脚本会校验 `allow_users` 都有 `authorized_keys`, 否则拒绝执行（避免锁死） |
| `ssh_rollback_after_minutes` | `5` | deadman 自动回滚窗口 |

---

## Phase 一览

| # | Phase | 脚本 | 需要 sudo? | 默认 |
|---|---|---|---|---|
| 01 | 环境检查 | `scripts/01-preflight.sh` | 仅检测 | 必跑 |
| 02 | apt 基础依赖 | `scripts/02-base-deps.sh` | ✅ | 必跑, 已装则整体跳过 |
| 02a | hostname + timezone | `scripts/02a-system.sh` | ✅（hostnamectl/timedatectl） | `hostname` 或 `timezone` 提供时才跑 |
| 02b | zsh + oh-my-zsh | `scripts/02b-zsh.sh` | ✅（apt + chsh） | `install_zsh=true` 才跑 |
| 03 | nvm + Node | `scripts/03-node.sh` | ❌ 用户态 | 必跑 |
| 04 | Claude Code CLI | `scripts/04-claude-code.sh` | ❌ 用户态 | 必跑 |
| 05 | git 身份 | `scripts/05-git-identity.sh` | ❌ | 必跑 |
| 06 | 项目克隆 + 依赖 | `scripts/06-project.sh` | ❌ | `project_repo_url` 提供时才跑 |
| 07 | plugins / skills | `scripts/07-plugins-skills.sh` | ❌ | `install_plugins_skills=true` 才跑 |
| 08 | **SSH 加固** | `scripts/08-ssh-harden.sh` | ✅ | `harden_ssh=true` 才跑, **必须按下方对话流程**执行 |
| -- | 总检查 | `scripts/verify.sh` | ❌ | 必跑 |

每个脚本都是**幂等**的——重跑只会跳过已完成的部分。可以单独调用任意一个 phase, 不强制走完整序列。

---

## 执行约定

### 1. 命令包装（重要）

Claude Code 的 `Bash` 工具每次起新 shell, **不会** 自动 source `.zshrc` / `.bashrc`, 所以 nvm 装好后下一条 Bash 调用拿不到 `node` / `npm` / `npx`。本 skill 提供 `scripts/lib/with-env.sh`, 它在调用前 source nvm 并把 `~/.local/bin` 加进 PATH。

> Phase 03 之后, 任何需要 `node` / `npm` / `npx` / `claude` 的 Bash 命令, 必须用：
> ```bash
> bash $REPO_DIR/scripts/lib/with-env.sh -- <你的命令>
> ```
> 例如：`bash ~/server-bootstrap/scripts/lib/with-env.sh -- claude --version`

### 2. 仓库定位

执行前把 `REPO_DIR` 指向本仓库的本地 clone（默认 `~/server-bootstrap`）。所有 phase 脚本都假设可通过 `$REPO_DIR/scripts/...` 找到自己。

```bash
export REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"
[ -d "$REPO_DIR/.git" ] \
  && git -C "$REPO_DIR" pull --ff-only \
  || git clone https://github.com/bytsm54/server-bootstrap.git "$REPO_DIR"
```

### 3. Phase 之间的状态

每个脚本退出码：`0` = 成功（含「已完成, 跳过」）, 非 0 = 失败。失败立即停止, 报错给用户, **不要试图绕过**。

---

## 执行流程

按顺序调用：

```bash
export REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"

bash "$REPO_DIR/scripts/01-preflight.sh"
bash "$REPO_DIR/scripts/02-base-deps.sh"

# 可选 phase 02a（hostname / timezone 任一非空即跑）
if [ -n "${hostname:-}" ] || [ -n "${timezone:-}" ]; then
  bash "$REPO_DIR/scripts/02a-system.sh" \
    ${hostname:+--hostname "$hostname"} \
    ${timezone:+--timezone "$timezone"}
fi

# 可选 phase 02b（必须在 03-node 之前跑, 让 .zshrc 创建顺序对）
if [ "${install_zsh:-false}" = "true" ]; then
  bash "$REPO_DIR/scripts/02b-zsh.sh" --theme "${zsh_theme:-agnoster}"
fi

bash "$REPO_DIR/scripts/03-node.sh"        --node-version "${node_version:-lts}" --npm-registry "${npm_registry:-official}"
bash "$REPO_DIR/scripts/04-claude-code.sh"  --method "${claude_install_method:-auto}" ${claude_version:+--version "$claude_version"}
bash "$REPO_DIR/scripts/lib/with-env.sh" -- bash "$REPO_DIR/scripts/05-git-identity.sh" --name "$git_user_name" --email "$git_user_email"

# 可选 phase 06
if [ -n "${project_repo_url:-}" ]; then
  bash "$REPO_DIR/scripts/lib/with-env.sh" -- bash "$REPO_DIR/scripts/06-project.sh" \
    --repo "$project_repo_url" \
    --dir  "${project_dir:-}" \
    --env-keys "${project_env_keys:-}"
fi

# 可选 phase 07：必须 agent 主动询问用户挑选
if [ "${install_plugins_skills:-false}" = "true" ]; then
  # 详见下文「Phase 07 交互」
  bash "$REPO_DIR/scripts/lib/with-env.sh" -- bash "$REPO_DIR/scripts/07-plugins-skills.sh" \
    --plugins-yaml "$REPO_DIR/templates/plugins.yaml" \
    --skills-yaml  "$REPO_DIR/templates/skills.yaml" \
    --selection "$selection_json"  # 见下
fi

# 可选 phase 08：高风险, 必须按下方「Phase 08 强制对话流程」执行, 不要"一气呵成"
if [ "${harden_ssh:-false}" = "true" ]; then
  : # 见下文「Phase 08 强制对话流程」
fi

bash "$REPO_DIR/scripts/lib/with-env.sh" -- bash "$REPO_DIR/scripts/verify.sh"
```

### Phase 07 交互（重要）

**不要** 默认安装 `templates/*.yaml` 里的任何条目, 这些只是常见推荐清单。流程：

1. 读取 `$REPO_DIR/templates/plugins.yaml` 和 `$REPO_DIR/templates/skills.yaml`
2. 把每一项的 `id` / `description` / `side_effects` 完整呈现给用户
3. 询问用户：选哪几项？（全跳过 / 全装 / 选编号 / 加自定义项）
4. 只把用户**明确选中**的传给 `07-plugins-skills.sh` 的 `--selection`（JSON 数组）

例：
```json
{
  "plugins": ["superpowers"],
  "skills":  ["skill-creator", "skill-vetter"],
  "extra_plugins": [],
  "extra_skills":  []
}
```

带 `side_effects` 提示的项（如 `claude-mem` 自动记录会话）必须当面读给用户确认, 不要静默勾选。

---

### Phase 08 强制对话流程（高风险, 不要跳过任何步骤）

**Phase 08 不允许"一气呵成"自动执行。** Agent 必须严格按下面 5 步走, 任何一步用户没明确确认就停下等待。

**步骤 1 — 念警告（必读）**

完整复制以下文字给用户, **逐字念**, 不要简化：

> 我即将修改 sshd 配置：
> - 端口 → `${ssh_port}`
> - 允许用户 → `${ssh_allow_users}`
> - PermitRootLogin → `${ssh_permit_root}`
> - PasswordAuthentication → `${ssh_password_auth}`
>
> 修改会**立刻生效**（systemctl reload sshd, 当前 SSH 会话不会断）。
>
> 同时我会调度一个 **${ssh_rollback_after_minutes} 分钟的 deadman**：
> 如果在窗口内你没回来确认能用新端口登录, 系统会**自动回滚**到当前配置。
>
> **执行前请你做两件事**：
> 1. 如果这台机器在云平台（AWS / 阿里云 / 腾讯云 / GCP 等）, 现在就去把端口
>    `${ssh_port}` 加进入站安全组规则, 否则即使 sshd 接受连接, 包也到不了。
> 2. 现在另开一个终端窗口（不要关闭当前这个）, 准备好命令：
>    `ssh -p ${ssh_port} <user>@<this-host>`
>
> 你已准备好了吗？请回复 **"已准备"** 继续, 或 **"取消"** 终止 phase 08。

**步骤 2 — 等用户回应**

- 用户回 "已准备" → 进步骤 3
- 用户回 "取消" 或任何犹豫 → 直接 return, 不调脚本, 告诉用户 phase 08 已跳过
- 用户没正面回答 → **不要继续**, 重念一遍警告

**步骤 3 — 调用 apply**

```bash
"${SUDO[@]}" bash "$REPO_DIR/scripts/08-ssh-harden.sh" apply \
  --port "$ssh_port" \
  --allow-users "$ssh_allow_users" \
  --permit-root "${ssh_permit_root:-no}" \
  --password-auth "${ssh_password_auth:-no}" \
  --rollback-after-minutes "${ssh_rollback_after_minutes:-5}"
```

apply 已经做了：备份 + 写新配置 + sshd -t + reload + 调度 deadman。退出码非 0 就立即停, **不要尝试 confirm**, 让 deadman 兜底（或你手动 rollback）。

**步骤 4 — 让用户在另一个终端验证**

把脚本最后打印的"下一步"原样转给用户：

> 现在请在另一个终端尝试：`ssh -p ${ssh_port} <user>@<host>`
>
> 登上来了 → 回这边回复 **"成功"**
> 登不上 / 没反应 → 回这边回复 **"失败"**, 或者什么都不做等 ${ssh_rollback_after_minutes} 分钟自动回滚

**步骤 5 — 根据回应处理**

- 用户回 "成功"：调 `bash $REPO_DIR/scripts/08-ssh-harden.sh confirm` 取消 deadman, 报告"加固成功"
- 用户回 "失败"：调 `bash $REPO_DIR/scripts/08-ssh-harden.sh rollback` 立即回滚, 报告"已回滚, 当前用回旧配置"
- 用户没回应、超过窗口期：deadman 已自动 rollback, agent 主动提醒用户"已自动回滚"

无论哪条分支, **都要紧接着调一次 verify.sh**, 确认 sshd 当前真实状态。

---

## 完成后

`verify.sh` 会打印一段总结：

```
✅ Node:        v22.x.x
✅ npm:         10.x.x
✅ Claude Code: 0.x.x
✅ git user:    <name> <email>
✅ 项目:        <project_dir>  (若适用)
✅ Plugins:     N installed
✅ Skills:      N installed
```

如果任何一项打 ❌, 看 `references/troubleshooting.md` 里的对应章节。

---

## 不在本 skill 范围内（明确划清）

- **fail2ban / 入侵检测 / WAF**：本 skill 的 SSH 加固 phase 08 仅做配置层（端口 / 允许用户 / 禁密码 / 禁 root）, 不装 fail2ban 类运行时防御。
- **域名 / 反代 / nginx / Docker**：超出"开发环境就绪"范畴。
- **数据库安装**：项目自决, 用 `06-project.sh` 检测到 `docker-compose.yml` 时仅提示, 不自动执行。
- **secret 写到 shell rc**：所有 token / API key 都引导用户写到 `<project>/.env`（且 gitignore 它）, 永不写 `~/.zshrc` / `~/.bashrc`。
