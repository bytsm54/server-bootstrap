# server-bootstrap

通用 Ubuntu 服务器初始化 Skill，也可通过脚本独立运行。完成基础工具、主机名与时区、Git 身份、SSH 加固和 fail2ban 配置；Node、Bun、zsh 及项目准备按需启用。

使用前先连接目标服务器；通过助手调用时，提前加载本 Skill。项目不保存服务器地址、私钥路径或连接记录，不安装助手工具及其他 Skills。仅支持运行 systemd 的 Ubuntu，不自动整机升级、重启或安装业务服务。

## 开始使用

建议用已有的普通 sudo 管理账号执行，脚本会在系统操作时调用 sudo。仅有 root 时，初始化入口会引导建立普通管理账号，先验证其公钥登录和 sudo，再继续关闭 root 登录。

在服务器终端中运行：

```bash
git clone https://github.com/bytsm54/server-bootstrap.git ~/server-bootstrap
bash ~/server-bootstrap/scripts/server-init.sh
```

也可使用一行引导入口：

```bash
curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
```

引导入口只获取本项目并启动同一个初始化脚本；缺少下载工具时安装 Git、curl 和 CA 证书。已有目录会核对 origin 并使用当前版本，不自动拉取代码。管道输入时，交互提示从 `/dev/tty` 读取。

## 参数和默认值

**主机名、SSH 端口由用户填写，留空保持现状。SSH 端口没有预设值。**

| 参数 | 默认行为 |
|---|---|
| `--hostname` | 空，不修改主机名 |
| `--ssh-port` | 空，保留当前实际 SSH 监听端口；自定义范围 `1–65535` |
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
| `--install-zsh` | `no` |
| `--zsh-theme` | `robbyrussell`，仅安装 zsh 时生效 |
| `--repo` | 空，不克隆项目、不安装项目依赖 |
| `--project-dir` | 提供仓库后默认为 `~/<仓库名>` |
| `--env-keys` | 空；可传逗号分隔的环境变量名，只创建缺失的 `.env` 占位文件 |

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

## SSH 修改流程

1. 展示当前与目标配置；先在另一终端验证允许账号的公钥登录和 sudo。修改端口时，先在实际使用的主机防火墙与外部访问规则中放行目标端口。
2. 检查端口范围和监听归属。填写当前 SSH 端口合法；其他服务或 SSH 转发占用的端口会被拒绝。
3. 备份配置，启用并记录 `at` 自动回滚任务，再写配置。执行语法检查、生效配置检查和实际监听检查；检测失败立即回滚。
4. 保持原会话，建立第二个新连接验证。验证时禁用 ControlMaster 连接复用并强制公钥认证（具体选项见 Skill）；成功后确认并取消回滚；失败或超时恢复原配置，并核对恢复后的监听。
5. SSH 状态确认后配置 fail2ban。它读取实际端口，验证配置、服务、自启和 sshd jail 的运行参数。

SSH 阶段使用并发锁；未确认的修改必须先确认或回滚，不能重复覆盖。普通服务使用 reload；Ubuntu socket activation 会检测实际 SSH socket，调整端口时保留其监听地址，并检查主服务的 `KillMode=process` 及对应 socket 依赖后重启 socket 同步监听、保留现有会话。自定义终止策略不满足要求时在修改前拒绝。脚本不代管云平台访问规则，也不将“本地监听成功”等同于“外部连接已成功”。

## 分阶段使用

交互终端可直接运行完整入口。助手或无交互执行器先完成普通阶段：

```bash
bash ~/server-bootstrap/scripts/server-init.sh --stage prepare --yes \
  --git-name 'Your Name' --git-email you@example.com
```

此命令不执行 SSH 和 fail2ban；其结果只表示普通阶段完成。按 [SKILL.md](SKILL.md) 的 SSH 流程完成剩余阶段后，再用相同目标参数验收：

```bash
bash ~/server-bootstrap/scripts/server-init.sh --stage verify
```

自定义过主机名、SSH 端口、可选运行环境等配置时，验收命令应携带同样的参数。验收分为“成功、跳过、失败、未验证”；失败或必需证据未验证时返回非零。`scripts/verify.sh` 是同一个验收实现的兼容入口。

## 配置与项目保护

- 基础包按功能安装；Python 辅助程序使用本项目 `.venv`。Python 项目使用项目自己的 `.venv`，不向系统 Python 安装依赖。
- Shell 配置只更新 `# BEGIN server-bootstrap:...` / `# END server-bootstrap:...` 之间的管理块，写入前备份并原子替换，保留其他内容。`with-env.sh` 只调整当前进程环境，不删除工具或软链。
- Node 使用 nvm，先解析已安装版本再决定是否安装。新安装 nvm 时验证固定 tag 对应的 commit，验证通过才加载。`china` 使用国内镜像；`official` 使用上游源。Bun 使用官方发布的二进制包。
- 项目目录已存在时核对 origin，发现本地改动即停止，不自动拉取或切换版本。按识别到的锁文件安装依赖；`poetry.lock`、`pdm.lock`、`Pipfile.lock` 暂不自动处理，检测到会停止而不回退为无锁安装；所需包管理器未安装时明确失败，不隐式安装全局工具。
- 只在 `.env` 不存在时创建权限为 `600` 的占位文件；已有文件保持原样。环境变量值由用户在项目中填写，不写入 Shell 配置。

## 脚本索引

| 文件 | 用途 |
|---|---|
| `scripts/bootstrap.sh` | 获取项目并启动初始化 |
| `scripts/server-init.sh` | 统一参数、交互与阶段编排 |
| `scripts/01-preflight.sh` | Ubuntu、systemd 与权限检查 |
| `scripts/02-base-deps.sh` | 按需安装基础包并建立专用 venv |
| `scripts/02a-system.sh` | 主机名、时区 |
| `scripts/02b-zsh.sh` | 可选 zsh、主题及 Shell 配置 |
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
