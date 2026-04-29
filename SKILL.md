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

第一次进入 skill 时, 一次性把下面的参数收齐再开始执行——不要中途反复打断用户。**用户没主动提到的可选参数, 必须按下面"开场对话协议"把对应可选 phase 摆出来让用户选, 严禁默认跳过然后只在结尾才告诉用户跳过了什么。**

### 必填

| 参数 | 说明 |
|---|---|
| `git_user_name` | git 全局 `user.name`, 用于 commit 署名 |
| `git_user_email` | git 全局 `user.email` |

### 可选（默认值见下表, 用户可在开场对话里覆盖）

> **本 skill 的默认配置是"推荐"路径** — 即开场对话里所有可选 phase 都默认 ON, 用户只需要明确说"跳过 X"才会跳过。
> 想关闭推荐默认, 在调用 SKILL 时显式传 `install_zsh=false` / `harden_ssh=false` 之类即可。

| 参数 | 默认 | 说明 |
|---|---|---|
| `hostname` | （空, 跳过） | 设系统 hostname, 同步 /etc/hosts 127.0.1.1 行 |
| `timezone` | `Asia/Shanghai` | 设时区, 如 `Asia/Shanghai`、`UTC`、`America/New_York`。空字符串才跳过 |
| `node_version` | `lts` | nvm install 的 Node 版本, 如 `lts`、`20`、`22.5.0` |
| `npm_registry` | `official` | `china` (npmmirror.com) 或 `official` (npmjs.org)。**中国大陆用户强烈建议设 `china`** |
| `claude_install_method` | `auto` | `auto`（github 失败回落 curl）/ `github`（GitHub releases 直下二进制, **国内推荐**, 走 github.com 不经 Cloudflare）/ `curl`（claude.ai/install.sh, 国内常 403）。**npm 方式已被 Anthropic 弃用, 本 skill 不再提供** |
| `claude_version` | （空）= latest | 显式钉版本如 `v2.1.119`, 跳过 GitHub API 查询（API 60 次/小时限流时有用） |
| `install_zsh` | `true` | 进入 phase 02b：装 zsh + oh-my-zsh + agnoster 主题 + 设默认 shell。`false` 跳过 |
| `zsh_theme` | `agnoster` | 仅 `install_zsh=true` 时生效, 任何 oh-my-zsh 内置主题名都行 |
| `project_repo_url` | （空, 跳过 phase 06） | 要克隆的项目 git URL |
| `project_dir` | `~/<repo basename>` | 克隆目标路径 |
| `project_env_keys` | （空） | 项目需要的环境变量 key 列表（如 `TUSHARE_TOKEN,OPENAI_API_KEY`）, phase 06 会**引导用户填到 `.env`**, 不写 `~/.zshrc` |
| `install_plugins_skills` | `true` | 进入 phase 07; agent 会展示 `templates/*.yaml`, 默认勾选 `recommended: true` 项 |
| `harden_ssh` | `true` | **高风险**, 进入 phase 08。**注意**: 即使默认 true, 也必须按"Phase 08 强制对话流程"逐项确认 |
| `ssh_port` | `22022` | 1024-65535, 不能是 22 |
| `ssh_allow_users` | `ubuntu` | 逗号分隔, 如 `ubuntu,bytsm54`。**agent 必须先 `whoami` 校对**: 若当前用户不在列表里且 `ssh_password_auth=no`, 会被锁死 |
| `ssh_permit_root` | `no` | `no` 或 `yes` |
| `ssh_password_auth` | `no` | `no` 或 `yes`. 选 `no` 时脚本会校验 `allow_users` 都有 `authorized_keys`, 否则拒绝执行（避免锁死） |
| `ssh_rollback_after_minutes` | `5` | deadman 自动回滚窗口 |
| `enable_fail2ban` | `true` | 进入 phase 09: 装 fail2ban + 配 sshd jail 防暴力破解。即使 `harden_ssh=false` 也可独立开 (jail 监听 22) |

---

## 开场对话协议（强制, 必须把推荐默认值摆给用户确认）

**触发条件**：用户在调用 SKILL 时**只给了必填参数**（git_user_name / git_user_email）, 或者下面任一可选参数**没显式提到**：
- `hostname` / `timezone`（→ phase 02a）
- `install_zsh`（→ phase 02b）
- `project_repo_url`（→ phase 06）
- `install_plugins_skills`（→ phase 07）
- `harden_ssh` / `enable_fail2ban`（→ phase 08 / 09）

→ Agent **必须**在跑任何 phase 之前, 一次性把下面 6 块内容发给用户让其确认, 不允许"先跑完必跑 phase 再说"。

**预备动作**（发对话前 agent 先做）：
- `whoami` 拿到当前用户名, 如果不是 `ubuntu`, 在 phase 08 那块把 `ssh_allow_users` 默认值改成实际用户名（避免锁死）
- 默认 plugins/skills 选择 = `templates/plugins.yaml` 和 `skills.yaml` 里所有 `recommended: true` 的项

**对话模板**（原样发, 把 `<name>` `<email>` 替换成用户传的值, `<allow-user>` 替换成 `whoami` 结果）：

```
收到。git 身份会配成 <name> <email>。

我已按推荐默认勾好 5 个可选 phase, 不需要的回 "跳过 X" (例: "跳过 02a"),
想改参数直接说 (例: "ssh 端口改 33333", "不要 claude-mem")。
一句 "全用默认" 我就按下面跑 (phase 08 仍会逐项确认)。

【02a】系统配置 — 时区
  ✅ 默认: timezone=Asia/Shanghai
  可选: hostname (默认不动)
  关掉: 回 "跳过 02a"

【02b】装 zsh + oh-my-zsh + agnoster 主题
  ✅ 默认: 装 (fonts-powerline 已由 phase 02 装好)
  可改: zsh_theme=<其他 omz 内置主题>
  关掉: 回 "跳过 02b"

【06】克隆项目仓库 + 装语言依赖
  默认: 跳过 (没默认仓库)
  要做: 给 git URL, 可选 project_dir 和 .env keys (如 TUSHARE_TOKEN,OPENAI_API_KEY)

【07】装 Claude Code plugins / skills
  ✅ 默认 plugins: superpowers, claude-mem, claude-hud
  ✅ 默认 skills:  skill-creator, skill-vetter, find-skills
  其他可选项 (frontend-design / docx / pdf / xlsx / pptx / context7 / tushare-data 等)
  我可以读完整清单给你, 想加直接说 "07 加 xxx"

【08】SSH 加固
  ✅ 默认: port=22022, allow_users=<allow-user>, 禁密码, 禁 root, deadman=5min
  ⚠️ 高风险, 错配会锁死。进入后会按"Phase 08 强制对话流程"再逐项确认。
  ⚠️ 云平台请先开放 22022 入站; 若 allow_users 跟你 SSH 用的不一致, 必须先改
  可改: ssh_port / ssh_allow_users / ssh_permit_root / ssh_password_auth
  关掉: 回 "跳过 08"

【09】装 fail2ban (防 SSH 暴力破解)
  ✅ 默认: 装, 监听 phase 08 的 ssh_port (跳过 08 时监听 22)
            findtime=10min, maxretry=5, bantime=1h
  关掉: 回 "跳过 09"
```

**处理规则**：

| 用户回答 | 处理 |
|---|---|
| 一句 "全用默认" / "推荐设置" / "都按你说的" | 按上述默认全跑, phase 08 仍走强制对话流程 |
| 对个别 phase 说 "跳过 X" 或改参数, 其他没提 | 没提的按推荐默认, 改的按用户说的, 不再二次确认 (默认是已知意图) |
| 一句 "全跳过" | 只跑必跑 phase (01/02/03/04/05/verify), 不再问 |
| 用户说 "你看着办" / 不明确 | 按推荐默认走, 跟"全用默认"等价 |

**反面教材**（不要这样做）：
- ❌ 把 6 个 phase 拆成 6 轮对话挨个问 (用户明确说过"不要中途反复打断")
- ❌ 不 `whoami` 就直接用 `ssh_allow_users=ubuntu` 默认, 在非 ubuntu 用户上跑会锁死
- ❌ 跳过 phase 08 的强制对话流程, 即便 `harden_ssh=true` 是默认值

---

## Phase 一览

| # | Phase | 脚本 | 需要 sudo? | 默认 |
|---|---|---|---|---|
| 01 | 环境检查 | `scripts/01-preflight.sh` | 仅检测 | 必跑 |
| 02 | apt 基础依赖 | `scripts/02-base-deps.sh` | ✅ | 必跑, 已装则整体跳过 |
| 02a | hostname + timezone | `scripts/02a-system.sh` | ✅（hostnamectl/timedatectl） | `hostname` 或 `timezone` 提供时才跑 |
| 02b | zsh + oh-my-zsh | `scripts/02b-zsh.sh` | ✅（apt + chsh） | `install_zsh=true` 才跑 |
| 03 | nvm + Node + bun | `scripts/03-node.sh` | ❌ 用户态 | 必跑（bun 是 claude-mem 等 plugin hook 依赖, 同时装 .bashrc/.zshrc/.zshenv 三处 PATH 注入） |
| 04 | Claude Code CLI | `scripts/04-claude-code.sh` | ❌ 用户态 | 必跑 |
| 05 | git 身份 | `scripts/05-git-identity.sh` | ❌ | 必跑 |
| 06 | 项目克隆 + 依赖 | `scripts/06-project.sh` | ❌ | `project_repo_url` 提供时才跑 |
| 07 | plugins / skills | `scripts/07-plugins-skills.sh` | ❌ | `install_plugins_skills` 默认 true |
| 08 | **SSH 加固** | `scripts/08-ssh-harden.sh` | ✅ | `harden_ssh` 默认 true, **必须按下方对话流程**执行 |
| 09 | fail2ban (sshd jail) | `scripts/09-fail2ban.sh` | ✅ | `enable_fail2ban` 默认 true; 装在 08 之后, 监听 ssh_port |
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

**仓库在 bootstrap.sh 阶段已经 clone 到 `~/server-bootstrap`** — 进 SKILL 时一定存在, agent 不要再宣布"克隆仓库"作为步骤, 直接进 phase 01。

只需要导出 `REPO_DIR` 给 phase 脚本使用; 顺带 `git pull` 拉最新（bootstrap.sh 跟 SKILL 调用之间可能隔了一段时间, 仓库可能有更新）：

```bash
export REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"
git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null || true
```

如果罕见地仓库不见了（用户手动 rm 了或 bootstrap.sh 没跑）, agent 应**直接报错**让用户重跑 bootstrap.sh, 不要在 SKILL 里偷偷重新 clone。

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
if [ "${harden_ssh:-true}" = "true" ]; then
  : # 见下文「Phase 08 强制对话流程」
fi

# 可选 phase 09：fail2ban
# 透传 ssh_port: 如果 phase 08 跑了, 用 08 用过的端口; 否则默认 22 (传统 sshd 端口)
if [ "${enable_fail2ban:-true}" = "true" ]; then
  bash "$REPO_DIR/scripts/09-fail2ban.sh" --ssh-port "${ssh_port:-22}"
fi

bash "$REPO_DIR/scripts/lib/with-env.sh" -- bash "$REPO_DIR/scripts/verify.sh"
```

### Phase 07 交互（重要）

**默认推荐项**：YAML 里 `recommended: true` 的条目, 当前是
- plugins: `superpowers` / `claude-mem` / `claude-hud`
- skills:  `skill-creator` / `skill-vetter` / `find-skills`

流程：

1. 读取 `$REPO_DIR/templates/plugins.yaml` 和 `$REPO_DIR/templates/skills.yaml`
2. 在开场对话里已展示了默认勾选项 (见上方对话模板的【07】块)
3. 用户回 "全用默认" / 没说要改 → selection = 所有 `recommended: true` 项
4. 用户说 "07 加 xxx" → 加进 selection; 说 "不要 xxx" → 从 selection 剔除
5. 用户想看完整清单 → 把每一项的 `id` / `description` / `side_effects` 全列出来再让选

**示例 selection JSON（默认推荐）**：
```json
{
  "plugins": ["superpowers", "claude-mem", "claude-hud"],
  "skills":  ["skill-creator", "skill-vetter", "find-skills"],
  "extra_plugins": [],
  "extra_skills":  []
}
```

用户用本 skill 时已默认接受推荐项的副作用; 不用在开场对话主动复述每条 `side_effects`。只在用户**问起某项**或**自己加非默认项**(如 context7 / tushare-data) 时再读 `side_effects` 给他听。

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

- **入侵检测 / WAF / nftables 自定义规则**：phase 09 仅装 fail2ban + 配 sshd jail 防 SSH 暴力破解, 不做更复杂的防御层。
- **域名 / 反代 / nginx / Docker**：超出"开发环境就绪"范畴。
- **数据库安装**：项目自决, 用 `06-project.sh` 检测到 `docker-compose.yml` 时仅提示, 不自动执行。
- **secret 写到 shell rc**：所有 token / API key 都引导用户写到 `<project>/.env`（且 gitignore 它）, 永不写 `~/.zshrc` / `~/.bashrc`。
