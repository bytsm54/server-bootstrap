# server-bootstrap

把一台**全新的 Ubuntu / Debian 服务器**变成「Claude Code 可用 + git 配好 + 项目可选就位」的可用环境。

- ✅ Node / nvm / Claude Code 全部装到**用户态**（`$HOME` 下）, 不污染系统
- ✅ 仅 apt 基础依赖一个步骤可能需要 sudo（且已装则跳过）
- ✅ 每个 phase 都**幂等**, 可重跑、可单独跑
- ✅ Plugin / skill 安装**默认关闭**, 由用户从清单中明确挑选
- ✅ Token / 环境变量永远写到项目 `.env`, **不**塞进 `~/.zshrc`
- ✅ **不**碰 sshd / 防火墙（避免把自己锁出来, 那是另一个 skill 的事）

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
├── SKILL.md                     # Claude Code skill 入口（编排 + 参数 + 交互约定）
├── scripts/
│   ├── bootstrap.sh             # 一键入口（curl | bash 用）
│   ├── 01-preflight.sh          # OS / 网络 / sudo 检测
│   ├── 02-base-deps.sh          # apt 依赖（唯一可能 sudo 的 phase）
│   ├── 03-node.sh               # nvm + Node LTS（用户态）
│   ├── 04-claude-code.sh        # Claude Code CLI（用户态）
│   ├── 05-git-identity.sh       # git 全局身份
│   ├── 06-project.sh            # 可选：clone + 装语言依赖 + 引导写 .env
│   ├── 07-plugins-skills.sh     # 可选：按 yaml 选项装 plugin / skill
│   ├── verify.sh                # 总检查 + 摘要
│   └── lib/
│       └── with-env.sh          # 包装：自动 source nvm + 加 PATH
├── templates/
│   ├── plugins.yaml             # 推荐 plugin 清单（不会自动装）
│   └── skills.yaml              # 推荐 skill 清单（不会自动装）
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

1. **零 sudo 默认**：把"必须 sudo"压到只剩 apt 那一步, 且已装则跳过
2. **幂等**：每个脚本以"已是目标状态就退出 0"为前提, 让重跑安全
3. **可选即关闭**：所有不属于"环境就绪"核心的能力（项目克隆、plugin、skill）默认关闭, 用户主动开启
4. **不藏 secret**：所有写文件操作明确告诉用户写到哪里, 凡是 `*` 标记的敏感值都引导写到 gitignore 的 `.env`
5. **进程级隔离**：除 git 全局身份以外, 不动 `~/.bashrc` / `~/.zshrc`（nvm 装好时会动一次, 是 nvm 自身行为）

---

## 不在范围内

| 项目 | 为什么 |
|---|---|
| SSH 加固 / 改端口 / fail2ban | 风险高、单独成 skill 更合适 |
| nginx / 反代 / 域名 | 项目级问题, 不通用 |
| Docker / k8s 安装 | 项目自决 |
| 写 secret 到 `~/.zshrc` | 不安全, 引导写到 `<project>/.env` 即可 |

---

## License

MIT
