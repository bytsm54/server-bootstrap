# 排错说明

先保留失败输出和退出码，处理具体失败后重跑对应阶段。不要通过删除用户配置、工具或 SSH 恢复记录来绕过错误。

## Agent 执行时没有交互终端

Agent 在对话中收集参数，再调用阶段脚本，按 [Skill 流程](../SKILL.md) 继续完成 SSH、fail2ban 和验收，不需要先把用户转到 Shell 里操作。普通阶段也可批量调用 `server-init.sh --stage prepare --yes`，并显式提供缺少的参数；不要在无交互执行器里启动完整入口等待 stdin。

独立终端方式下，`curl | bash` 的标准输入是脚本内容，入口会打开 `/dev/tty` 收集参数。`--yes` 不能代替 SSH 第二连接验证，`--stage prepare` 成功也不表示完整初始化已结束。

## Agent 的命令沙箱启动失败

若连 `id` 都在执行前出现 `bwrap: loopback: Failed RTM_NEWADDR: Operation not permitted`，先排查执行器环境，不能判为本项目阶段脚本失败。在权限策略允许时，通过正常审批运行只读诊断，确认 Ubuntu 版本、`bubblewrap` 安装情况及内核 AppArmor 拒绝日志。

缺少系统版 `bubblewrap` 时，执行器的内置副本可能不匹配 Ubuntu 已加载的 AppArmor profile。经授权修复执行环境时，优先使用 Ubuntu 软件包和对应 profile，再验证原沙箱中的命令执行；不要默认关闭全局 AppArmor 限制。执行器修复不属于本 Skill 的默认初始化步骤。

## Ubuntu、systemd 或 sudo 检查失败

只支持运行 systemd 的 Ubuntu。普通容器、未启动 systemd 的环境不会通过预检。

root 执行系统阶段时不需要 sudo；普通用户需要可用 sudo。仅有 root 账号时，先创建普通管理账号并加入 sudo 组，为它配置公钥，从新终端验证登录和 sudo，再继续。不要把整套用户态安装命令套在 `sudo` 下，否则配置可能写进 root 的主目录。

在 Agent 沙箱中无法访问 systemd 总线或执行 sudo，并不代表宿主机缺少相应能力；在权限策略允许时，通过正常审批重新检查。对于已有免密 sudo 的账号，以 `sudo -n id -u` 成功输出 `0` 验证提权能力；`sudo -v` 可能仍要求密码，不应单独作为失败依据。确实需要密码时，在同一连接的交互终端中完成认证后重试，不将密码写入脚本或日志。

## Python venv 创建失败

先运行基础依赖阶段安装 `python3-venv`：

```bash
bash scripts/02-base-deps.sh
```

默认辅助环境位于本项目 `.venv`；项目目录不可写时，可将 `BOOTSTRAP_VENV` 指向当前用户可写的专用位置，后续阶段和验收保持同一设置。业务项目使用其自己的 `.venv`。不要使用 `sudo pip` 或 `--break-system-packages` 回退到系统环境。

## 非交互 Shell 找不到 Node 或 Bun

新子进程不一定读取用户 rc 文件。使用环境包装器：

```bash
bash scripts/lib/with-env.sh -- node --version
bash scripts/lib/with-env.sh -- bun --version
```

Bun 阶段会在 `.zshenv` 中写入有界 PATH 块，可用 `zsh -lc 'bun --version'` 检查；只安装了旧版配置时重跑 Bun 阶段即可补齐。Node 交互配置会加载 nvm 补全。包装器只加载现有环境并调整进程 PATH，不删除软链或工具。nvm 是 Shell 函数；当前交互 Shell 可执行 `. "$HOME/.nvm/nvm.sh"` 加载。Node 和 Bun 默认不安装，先确认是否选择了对应选项。

## Node 镜像或版本校验失败

选择官方源重试：

```bash
unset NVM_SOURCE NVM_NODEJS_ORG_MIRROR NVM_INSTALLER_TAG NVM_EXPECTED_COMMIT
bash scripts/03-node.sh --node-version lts --npm-registry official
```

新 nvm 下载先验证 tag 对应的固定 commit，再加载代码。校验失败时不会执行未验证内容；保留的临时目录可供检查。只有明确选择其他可信版本时，才同时更新 tag 和对应 commit，不能为绕过校验直接接受下载结果。

已有 `~/.nvm` 但缺少有效 `nvm.sh` 时，先检查目录内容并保留需要的数据，再选择修复路径。不要直接删除整个目录，它可能含已有 Node 版本和全局包。

## Shell 配置管理块损坏或文件是软链

zsh + oh-my-zsh + powerlevel10k 默认安装，`--install-zsh no` 才跳过。用 `getent passwd "$(id -un)"` 核对账号的登录 Shell，并在新 SSH 会话中检查；已有 Bash 进程和它的 `$SHELL` 环境变量不能证明切换失败。首次交互登录出现 powerlevel10k 外观向导时按需选择，或之后在 zsh 中运行 `p10k configure`。完整验收还会实际加载 oh-my-zsh 和所选主题，只有 zsh 命令存在不算配置完成。

管理块使用明确的 BEGIN/END 标记。标记不配对、重复或文件是软链时停止，避免覆盖未知内容。检查原文件和旁边的 `.server-bootstrap.bak`，保留用户内容后修复管理块，再重跑对应阶段。

已有 zsh 配置使用自定义的 oh-my-zsh 加载方式时，可能无法找到插入主题设置的锚点。先检查配置如何加载主题，不要把整份 `.zshrc` 换成模板。语法可以通过 `zsh -n "$HOME/.zshrc"` 检查。

## 项目准备被拒绝或依赖失败

- origin 不匹配：核对传入仓库地址和目标目录，必要时选择另一目录。
- 存在本地改动：先由用户处理改动；脚本不自动 stash、reset、pull 或切换分支。
- 缺少包管理器：项目阶段会按需在用户目录准备 uv/Corepack，检查网络、npm 源和目录权限；Node/Bun 仍需按用户选择准备。检查 `packageManager` 版本与锁文件是否一致，不通过换管理器绕过锁文件。
- 编译失败：项目阶段按需安装 `build-essential` 和 Python 开发头文件；具体业务依赖仍以安装日志为准，脚本不自动部署业务服务。
- Python 依赖失败：检查项目 `.venv` 和安装日志；不向系统 Python 安装依赖。
- `.env` 已存在：内容保持不变。若被 Git 跟踪或是软链，先处理对应状态再填写凭据。

项目准备成功不包含业务启动或业务测试。验收依赖准备记录时还会核对当前提交，切换提交后需要重新准备。

## SSH 端口占用或无法识别监听

查看主服务与 socket 的实际状态：

```bash
sudo ss -ltnp
systemctl show ssh.service --property=MainPID
systemctl status ssh.socket
systemctl show ssh.socket --property=Listen
```

SSH 登录监听根据主进程及 active socket 归属识别；会话进程的反向转发端口不属于登录端口。自定义端口被其他服务占用时应更换端口或处理占用，不能强制覆盖。填写当前登录端口是合法的。

无法确认进程归属、socket 地址或实际端口时，脚本会停止，不会默认使用某个固定端口。socket 模式还会检查主服务的 `KillMode=process` 和对 SSH socket 的 `Requires` 依赖；自定义的终止策略不满足保留会话的条件时，先检查服务覆盖配置，不要直接绕过检查。

## SSH 新连接失败或超时

保持原会话，立即执行：

```bash
bash scripts/08-ssh-harden.sh rollback
```

也可等待已安排的自动回滚。当前截止时间可通过以下命令读取：

```bash
bash scripts/08-ssh-harden.sh deadline
```

新端口已监听但外部连接失败时，检查目标端口的主机防火墙、外部访问规则，以及允许账号、公钥和 sudo。仅在新连接确实成功后执行 `confirm`。截止时间已过时不能再确认，应检查回滚结果并重新开始。

备份及对应恢复脚本位于 `/var/backups/sshd-bootstrap/`。回滚不仅恢复配置，也会恢复 socket 设置并核对原监听。若恢复失败，脚本保留恢复记录，先查看错误、系统日志和备份，通过现有会话或控制台修复；不要手动删除记录假装恢复成功。

## SSH 配置未生效或存在 Include / Match 冲突

脚本检查语法和生效配置；其他 Include 中的端口、AllowUsers 或 Match 认证设置可能与目标冲突。检查：

```bash
sudo sshd -t
sudo sshd -T
sudo journalctl -u ssh -n 50
```

涉及用户或来源地址条件时，用 `sshd -T -C` 检查实际连接条件。不要仅根据某个配置文件包含目标文本就认定生效。先处理冲突，再重新执行 SSH 阶段。

## fail2ban 配置或 jail 不可用

SSH 尚有待确认或恢复记录时，先完成 SSH 状态处理。fail2ban 阶段自动读取实际端口，不接受手工传入的 SSH 端口。

```bash
sudo fail2ban-client -t
sudo systemctl status fail2ban
sudo journalctl -u fail2ban -n 50
sudo fail2ban-client status sshd
sudo fail2ban-client get sshd actions
# 使用上一步列出的动作名：
sudo fail2ban-client get sshd action <action> port
```

阶段安装 `fail2ban`、`python3-systemd` 及所选动作所需的防火墙工具（如 `iptables` 或 `nftables`），使用 systemd journal 作为日志来源；不要求 `/var/log/auth.log` 存在。托管配置位于 `/etc/fail2ban/jail.d/99-server-bootstrap.local`。继承系统或用户的 `action/banaction`，不会强制改为 iptables。验收同时检查动作集合、封禁命令、jail 参数及实际 SSH 端口；无法判定自定义动作的端口保护时报告失败，保留原配置供排查。配置及运行状态一致时不重启 jail；确需变更时重建 sshd jail，以兼容 fail2ban 1.1 的动作切换。

旧版带本项目标记的 `sshd.local` 会迁移托管键并保留用户 action、ignoreip 等选项；无标记的文件保持原样。SSH 旧 socket `override.conf` 也只迁移带标记的监听设置。迁移失败恢复备份，手工设置与目标冲突时不要直接删除用户文件。

## 验收显示未验证或返回非零

验收不会把缺少证据当成成功。常见原因包括 sudo 无法非交互执行、SSH 仍待确认、确认后配置发生变化，或项目未有成功准备记录。

先取得所需权限或完成对应验证，再携带原目标参数执行：

```bash
bash scripts/server-init.sh --stage verify
```

可选项未选择时显示“跳过”；不要为了消除失败而把原本选择的项目改成跳过。
