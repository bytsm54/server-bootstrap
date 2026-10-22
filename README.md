# server-bootstrap

**在 AI Agent 会话中执行的 Ubuntu 服务器初始化 Skill。** 可由 Codex、Claude Code 等支持 Skill 的 Agent 加载：用户提出初始化需求，Agent 检查服务器、收集参数、调用阶段脚本完成配置、处理失败并验收。

覆盖基础工具、主机名、时区、Git 身份、zsh + oh-my-zsh + powerlevel10k、SSH 加固和 fail2ban；Node、Bun 及项目准备按需启用。`SKILL.md` 是 Agent 的工作入口，`scripts/` 是它使用的执行工具。

用户提前完成目标服务器连接和本 Skill 的加载。Agent 可以在服务器上运行，也可以通过会话已有的远程执行通道操作服务器。本项目不负责 AI Agent 的安装、登录或配置，不保存服务器地址、私钥路径和连接记录，不安装其他 Skills。仅支持运行 systemd 的 Ubuntu，不自动整机升级、重启或安装业务服务。

## 在 Agent 中使用

加载本 Skill 后，在 Agent 会话里说：

> 执行 server-bootstrap，初始化当前连接的 Ubuntu 服务器。

也可以直接给出选择：

> 使用 server-bootstrap，主机名和 SSH 端口保持现状，时区设为 Asia/Shanghai，复用已有 Git 身份。安装 Node，Bun 和 zsh 不装，不克隆项目。

Agent 会按 [SKILL.md](SKILL.md) 完成以下工作：

1. 检查目标系统、账号、权限及已有配置，在对话中一次询问尚缺的参数。
2. 展示目标配置，按用户选择调用各阶段工具，处理安装或配置失败。
3. 完成 SSH 修改前后的独立连接验证，在成功后确认，失败或超时回滚。
4. 同步 fail2ban，执行完整验收并报告结果。

普通配置由 Agent 执行。用户主要提供选择和缺少的信息；需要用户客户端建立第二个 SSH 连接时，Agent 会给出具体验证方式，并根据结果继续操作。

建议使用已有的普通 sudo 管理账号。仅有 root 时，Agent 先协助准备普通管理账号，验证其公钥登录和 sudo，再继续关闭 root 登录。

## 对话中可选择的配置

**主机名留空保持现状；SSH 端口默认 `22022`，可自定义或选择保持现状。zsh 环境、SSH 加固和 fail2ban 默认开启。** 下表同时列出对应脚本参数，供 Agent 调用或独立运行时使用；在对话中直接描述选择即可。

| 参数 | 默认行为 |
|---|---|
| `--hostname` | 空，不修改主机名 |
| `--ssh-port` | `22022`；自定义范围 `1–65535`，传 `''` 保留当前实际端口，交互时输入 `keep` |
| `--timezone` | `Asia/Shanghai`；传 `''` 保持现状，交互时输入 `keep` |
| `--git-name` / `--git-email` | 复用已有全局 Git 身份，缺失时询问 |
| `--harden-ssh` | `yes` |
| `--ssh-allow-users` | 当前管理账号，多个用户名以逗号分隔 |
| `--ssh-permit-root` | `no` |
| `--ssh-password-auth` | `no`，同时关闭键盘交互认证 |
| `--ssh-rollback-minutes` | `5`，SSH 自动回滚窗口 |
| `--enable-fail2ban` | `yes`，跟随实际 SSH 端口 |
| `--install-node` | `no` |
| `--node-version` | `lts`，仅安装 Node 时生效 |
| `--npm-registry` | `china`，可选 `official` |
| `--install-bun` | `no`，可独立于 Node 安装 |
| `--install-zsh` | `yes`，安装 zsh + oh-my-zsh，将当前用户的默认 Shell 改为 zsh；传 `no` 跳过 |
| `--zsh-theme` | `powerlevel10k/powerlevel10k`，仅安装 zsh 时生效 |
| `--repo` | 空，不克隆项目、不安装项目依赖 |
| `--project-dir` | 提供仓库后默认为 `~/<仓库名>` |
| `--env-keys` | 空；可传逗号分隔的环境变量名，只创建缺失的 `.env` 占位文件 |

zsh 阶段同时安装 `fonts-powerline`、自动建议和语法高亮，保留自定义插件并补齐 `git sudo`。可用阶段参数 `--user <账号>` 为指定管理账号配置，用户文件以该账号身份写入。默认 Shell 的切换在新登录会话中生效；已有会话保持原 Shell。powerlevel10k 首次交互登录可能显示外观配置向导，也可在 zsh 中运行 `p10k configure` 调整。验收会检查 oh-my-zsh 和所选主题是否实际加载。

## SSH 修改流程

1. 展示当前与目标配置；先在另一终端验证允许账号的公钥登录和 sudo。修改端口时，先在实际使用的主机防火墙与外部访问规则中放行目标端口。
2. 检查端口范围和监听归属。填写当前 SSH 端口合法；其他服务或 SSH 转发占用的端口会被拒绝。
3. 备份配置，启用并记录 `at` 自动回滚任务，再写配置。执行语法检查、生效配置检查和实际监听检查；检测失败立即回滚。
4. 保持原会话，建立第二个新连接验证。验证时禁用 ControlMaster 连接复用并强制公钥认证（具体选项见 Skill）；成功后确认并取消回滚；失败或超时恢复原配置，并核对恢复后的监听。
5. SSH 状态确认后配置 fail2ban。它读取实际端口，验证配置、服务、自启和 sshd jail 的运行参数。

SSH 加固包含 `ClientAliveInterval 60` 和 `ClientAliveCountMax 3`，并核对生效值。SSH 阶段使用并发锁；未确认的修改必须先确认或回滚，不能重复覆盖。普通服务使用 reload；Ubuntu socket activation 会检测实际 SSH socket，调整端口时保留其监听地址，并检查主服务的 `KillMode=process` 及对应 socket 依赖后重启 socket 同步监听、保留现有会话。自定义终止策略不满足要求时在修改前拒绝。脚本不代管云平台访问规则，也不将“本地监听成功”等同于“外部连接已成功”。

## 独立脚本使用（可选）

需要脱离 Agent 直接在终端初始化时，可使用独立入口；它复用 Skill 使用的默认值、校验和阶段脚本：

```bash
git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
bash ~/server-bootstrap/scripts/server-init.sh
```

一行引导入口只获取本项目并启动上述初始化脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
```

缺少下载工具时，引导入口安装 Git、curl 和 CA 证书。已有目录会核对 origin 并使用当前版本，不自动拉取代码；管道输入时从 `/dev/tty` 读取交互输入。

交互入口在启用 Node 时询问版本与镜像，在启用 SSH 时询问 root/密码登录及回滚窗口；已明确传入的选项不重复询问。

完整选项及只读配置预览：

```bash
bash ~/server-bootstrap/scripts/server-init.sh --help
bash ~/server-bootstrap/scripts/server-init.sh --show-config
```

例如，保持主机名、SSH 端口与时区现状，启用 Node：

```bash
bash ~/server-bootstrap/scripts/server-init.sh \
  --hostname '' --ssh-port '' --timezone '' \
  --install-node yes --node-version lts --npm-registry official
```

`--yes` 表示已接受普通阶段参数，不会跳过 SSH 公钥验证、端口放行准备和第二连接确认。

`--stage prepare --yes` 只执行普通阶段，`--stage verify` 只做验收。Agent 默认按 Skill 分阶段编排，也可批量调用普通阶段，再继续完成 SSH、fail2ban 和完整验收。`prepare` 成功不代表整个初始化完成。

验收使用与请求一致的目标参数，区分“成功、跳过、失败、未验证”；失败或必需证据未验证时返回非零。`scripts/verify.sh` 是同一验收实现的兼容入口。

## 配置与项目保护

- 基础包按功能安装；Python 辅助程序使用本项目 `.venv`。Python 项目使用项目自己的 `.venv`，不向系统 Python 安装依赖。
- Shell 配置只更新 `# BEGIN server-bootstrap:...` / `# END server-bootstrap:...` 之间的管理块，写入前备份并原子替换，保留其他内容。`with-env.sh` 只调整当前进程环境，不删除工具或软链。
- Node 使用 nvm，先解析已安装版本再决定是否安装。新安装 nvm 时验证固定 tag 对应的 commit，验证通过才加载。恢复 nvm 的 Bash/zsh 补全；Bun PATH 同时写入 `.zshenv`，支持非交互 zsh。`china` 使用国内镜像；`official` 使用上游源。Bun 使用官方发布的二进制包。
- 项目目录已存在时核对 origin，发现本地改动即停止，不自动拉取或切换版本。按识别到的锁文件安装依赖；`poetry.lock`、`pdm.lock`、`Pipfile.lock` 暂不自动处理，检测到会停止而不回退为无锁安装；选择项目准备后，按需安装 `build-essential`（Python 项目另装 `python3-dev`）。缺少 uv 时安装到用户专用工具 venv；`pyproject.toml` 使用 uv 同步，已有 `uv.lock` 使用 `--frozen`。pnpm/yarn 按 `packageManager` 声明通过 [Corepack](https://github.com/nodejs/corepack) 准备，缺少 Corepack 时安装到本项目专用的用户目录，不覆盖全局工具或软链。Node/Bun 运行环境仍需单独启用；不同管理器的锁文件或版本声明冲突会停止。
- 升级旧版配置时，仅处理有本项目标记的旧 SSH socket `override.conf` 和 fail2ban `sshd.local` 中的托管设置，保留其他自定义内容并备份；失败时恢复。fail2ban 继承系统或用户的 `action/banaction`，按动作补齐防火墙依赖；配置和运行状态一致时不重启 jail。
- Git 身份和已有 `core.askPass` 选择保持不变；未设置 `core.askPass` 时写入空值。预检实际执行 sudo 提权测试，并按所选功能报告工具及源连通性。
- 只在 `.env` 不存在时创建权限为 `600` 的占位文件；已有文件保持原样。环境变量值由用户在项目中填写，不写入 Shell 配置。

## 脚本索引

| 文件 | 用途 |
|---|---|
| `SKILL.md` | Agent 主入口：对话、阶段编排、恢复与验收 |
| `scripts/bootstrap.sh` | 可选终端引导入口 |
| `scripts/server-init.sh` | 独立终端入口；共享参数、批量阶段与验收接口 |
| `scripts/01-preflight.sh` | Ubuntu、systemd 与权限检查 |
| `scripts/02-base-deps.sh` | 按需安装基础包并建立专用 venv |
| `scripts/02a-system.sh` | 主机名、时区 |
| `scripts/02b-zsh.sh` | 默认安装 zsh、oh-my-zsh、powerlevel10k，设置当前用户默认 Shell |
| `scripts/03-node.sh` / `scripts/03a-bun.sh` | 可选用户态运行环境 |
| `scripts/05-git-identity.sh` | Git 全局身份 |
| `scripts/06-project.sh` | 可选项目与依赖准备 |
| `scripts/08-ssh-harden.sh` | SSH apply、confirm、rollback、deadline |
| `scripts/09-fail2ban.sh` | 按实际端口配置 sshd jail |
| `scripts/verify-server.sh` | 验收及退出状态 |
| `scripts/lib/` | 共用默认值、校验、SSH 探测、配置更新和环境包装 |

失败后的恢复方法见 [排错说明](references/troubleshooting.md)。

## 本地回归测试

```bash
bash tests/run.sh
```

测试使用本项目 venv、临时目录和系统命令替身，覆盖参数、配置保留、SSH 确认/回滚、socket 监听和 fail2ban 同步，不连接服务器。它不能替代真实 Ubuntu 上的新连接及服务切换验收。

## License

MIT
