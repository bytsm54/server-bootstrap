# server-bootstrap

把一台**全新的 Ubuntu / Debian 服务器**变成「Claude Code / Codex 可用 + git 配好 + 项目可选就位」的可用环境。

- ✅ Node / nvm / Claude Code / Codex / RTK 全部装到**用户态**（`$HOME` 下）, 且由 bootstrap 统一 PATH: nvm 唯一接管 `node`/`npm`/`npx`, `codex` 绑定同一 npm prefix, 不污染系统
- ✅ 核心开发工具装到用户态；需要 sudo 的只有 apt、hostname/timezone、zsh 默认 shell、SSH、fail2ban 等系统级 phase
- ✅ 每个 phase 都**幂等**, 可重跑、可单独跑
- ✅ Plugin / skill 安装在 `bootstrap.sh` 最小路径里不执行；进入 skill 后按推荐默认勾选, 由用户确认或调整
- ✅ Token / 环境变量永远写到项目 `.env`, **不**塞进 `~/.zshrc`
- ✅ zsh + oh-my-zsh 是 skill 推荐默认 phase, 可用 `install_zsh=false` 关闭
- ✅ SSH 加固是 skill 推荐默认 phase, 但必须逐项确认, 自带 deadman 自动回滚 + 双终端验证流程

---

## 在新服务器上的最小路径

```bash
# 在新服务器 SSH 会话里跑这一行
curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
```

完成后：

```bash
claude     # 登录 Claude Code
```

进入 Claude Code 会话, 告诉它：

> 执行 server-bootstrap, git_user_name=YourName, git_user_email=you@example.com

它会读 `SKILL.md` 走剩下的 phase（git 身份 / 可选项目克隆 / 可选 plugin-skill / 总检查）。

---

## 目录结构

```
server-bootstrap/
├── SKILL.md                     # Agent skill 入口（编排 + 参数 + 交互约定）
├── scripts/
│   ├── bootstrap.sh             # 一键入口（curl | bash 用）
│   ├── 01-preflight.sh          # OS / 网络 / sudo 检测
│   ├── 02-base-deps.sh          # apt 依赖（含 at, 用于 phase 08 deadman）
│   ├── 02a-system.sh            # 可选：hostname + timezone
│   ├── 02b-zsh.sh               # 可选：zsh + oh-my-zsh + 主题 + 默认 shell
│   ├── 03-node.sh               # nvm + Node LTS（用户态）
│   ├── 04-claude-code.sh        # Claude Code CLI（用户态）
│   ├── 04a-codex.sh             # Codex CLI（npm -g @openai/codex）
│   ├── 04b-rtk.sh               # RTK + 注入 rtk 规则到 ~/.claude/CLAUDE.md 与 ~/.codex/AGENTS.md
│   ├── 05-git-identity.sh       # git 全局身份
│   ├── 06-project.sh            # 可选：clone + 装语言依赖 + 引导写 .env
│   ├── 07-plugins-skills.sh     # 可选：按 yaml 选项装 plugin / skill
│   ├── 07a-codex-skills.sh      # 自动：把 ~/.agents/skills 软链给 Codex 复用
│   ├── 08-ssh-harden.sh         # 可选：SSH 加固（apply/confirm/rollback 三模式 + deadman）
│   ├── 09-fail2ban.sh           # 可选：fail2ban sshd jail
│   ├── verify.sh                # 总检查 + 摘要
│   └── lib/
│       └── with-env.sh          # 包装：自动 source nvm + 加 PATH
├── templates/
│   ├── plugins.yaml             # 推荐 plugin 清单（进入 skill 后确认再装）
│   └── skills.yaml              # 推荐 skill 清单（进入 skill 后确认再装）
└── references/
    └── troubleshooting.md       # nvm / sudo / PATH / 重跑 排错
```

---

## 单独跑某个 phase

```bash
# 只装 Node
bash ~/server-bootstrap/scripts/03-node.sh --node-version lts

# 只配 git 身份
bash ~/server-bootstrap/scripts/05-git-identity.sh --name "Foo" --email "foo@bar.com"

# 只跑总检查
bash ~/server-bootstrap/scripts/lib/with-env.sh -- bash ~/server-bootstrap/scripts/verify.sh
```

---

## 设计原则

1. **用户态优先**：Node / Claude Code / Codex / RTK 放在 `$HOME` 下；系统级 phase 才申请 sudo
2. **幂等**：每个脚本以"已是目标状态就退出 0"为前提, 让重跑安全
3. **先确认再执行**：不属于"环境就绪"核心的能力会在 skill 开场一次性展示, 用户确认、修改或跳过后才执行
4. **不藏 secret**：所有写文件操作明确告诉用户写到哪里, 凡是 `*` 标记的敏感值都引导写到 gitignore 的 `.env`
5. **进程级隔离**：除 git 全局身份以外, 不动 `~/.bashrc` / `~/.zshrc`（nvm 装好时会动一次, 是 nvm 自身行为）

---

## 不在范围内

| 项目 | 为什么 |
|---|---|
| WAF / 入侵检测 / nftables 自定义规则 | phase 09 只覆盖 fail2ban sshd jail, 更复杂防御另开 skill |
| nginx / 反代 / 域名 | 项目级问题, 不通用 |
| Docker / k8s 安装 | 项目自决 |
| 写 secret 到 `~/.zshrc` | 不安全, 引导写到 `<project>/.env` 即可 |

---

## License

MIT
