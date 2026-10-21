# 排错说明

先保留失败输出和退出码，处理具体失败后重跑对应阶段。不要通过删除用户配置、工具或 SSH 恢复记录来绕过错误。

## 没有交互终端

`curl | bash` 的标准输入是脚本内容，入口会打开 `/dev/tty` 收集参数。无终端的执行器使用 `--stage prepare --yes` 并显式提供缺少的 Git 身份，再按 [Skill 流程](../SKILL.md) 单独完成 SSH 和 fail2ban。

`--yes` 不能代替 SSH 第二连接验证。`--stage prepare` 成功也不表示完整初始化已结束。

## Ubuntu、systemd 或 sudo 检查失败

只支持运行 systemd 的 Ubuntu。普通容器、未启动 systemd 的环境不会通过预检。

root 执行系统阶段时不需要 sudo；普通用户需要可用 sudo。仅有 root 账号时，先创建普通管理账号并加入 sudo 组，为它配置公钥，从新终端验证登录和 sudo，再继续。不要把整套用户态安装命令套在 `sudo` 下，否则配置可能写进 root 的主目录。

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

包装器只加载现有环境并调整进程 PATH，不删除软链或工具。nvm 是 Shell 函数；当前交互 Shell 可执行 `. "$HOME/.nvm/nvm.sh"` 加载。Node 和 Bun 默认不安装，先确认是否选择了对应选项。

## Node 镜像或版本校验失败

选择官方源重试：

```bash
unset NVM_SOURCE NVM_NODEJS_ORG_MIRROR NVM_INSTALLER_TAG NVM_EXPECTED_COMMIT
bash scripts/03-node.sh --node-version lts --npm-registry official
```

新 nvm 下载先验证 tag 对应的固定 commit，再加载代码。校验失败时不会执行未验证内容；保留的临时目录可供检查。只有明确选择其他可信版本时，才同时更新 tag 和对应 commit，不能为绕过校验直接接受下载结果。

已有 `~/.nvm` 但缺少有效 `nvm.sh` 时，先检查目录内容并保留需要的数据，再选择修复路径。不要直接删除整个目录，它可能含已有 Node 版本和全局包。

## Shell 配置管理块损坏或文件是软链

管理块使用明确的 BEGIN/END 标记。标记不配对、重复或文件是软链时停止，避免覆盖未知内容。检查原文件和旁边的 `.server-bootstrap.bak`，保留用户内容后修复管理块，再重跑对应阶段。

已有 zsh 配置使用自定义的 oh-my-zsh 加载方式时，可能无法找到插入主题设置的锚点。先检查配置如何加载主题，不要把整份 `.zshrc` 换成模板。语法可以通过 `zsh -n "$HOME/.zshrc"` 检查。

## 项目准备被拒绝或依赖失败

- origin 不匹配：核对传入仓库地址和目标目录，必要时选择另一目录。
- 存在本地改动：先由用户处理改动；脚本不自动 stash、reset、pull 或切换分支。
- 缺少包管理器：按锁文件要求准备相应工具，再重跑；不要通过更换包管理器绕过锁文件。
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
sudo fail2ban-client get sshd action iptables-multiport port
```

阶段安装 `fail2ban`、`python3-systemd` 和 `iptables`，使用 systemd journal 作为日志来源；不要求 `/var/log/auth.log` 存在。托管配置位于 `/etc/fail2ban/jail.d/99-server-bootstrap.local`。检查是否有其他配置覆盖该 jail；运行中的 action 端口必须与实际 SSH 端口一致。

## 验收显示未验证或返回非零

验收不会把缺少证据当成成功。常见原因包括 sudo 无法非交互执行、SSH 仍待确认、确认后配置发生变化，或项目未有成功准备记录。

先取得所需权限或完成对应验证，再携带原目标参数执行：

```bash
bash scripts/server-init.sh --stage verify
```

可选项未选择时显示“跳过”；不要为了消除失败而把原本选择的项目改成跳过。
