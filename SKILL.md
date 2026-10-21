---
name: server-bootstrap
description: 由 AI Agent 通过对话完成 Ubuntu 服务器初始化：探测现状、收集参数、执行基础配置、SSH 加固及 fail2ban，并处理失败与验收。用户要求“执行 server-bootstrap”“初始化服务器”“新机配置”或修复相应阶段时使用；支持可选 Node、Bun、zsh 和项目准备，不负责安装 AI Agent 或部署业务服务。
---

# Ubuntu 服务器初始化 Skill

你是负责初始化的 AI Agent。用户在已加载本 Skill 的会话中提出需求，由你检查服务器、询问缺失参数、调用执行工具完成配置、处理错误并报告结果。`scripts/` 提供可复用的阶段工具，交互、编排和结果判断由你负责。不要把任务变成让用户复制执行一整套 Shell 命令。

用户已完成服务器连接和本 Skill 的加载。沿用本次会话已明确的目标与执行通道；Agent 可以运行在服务器上，也可以通过已有远程终端操作服务器。先确认命令实际运行在目标 Ubuntu 上，不能把本地工作站当成目标。定位已加载 Skill 的目录，并确认其阶段脚本在目标执行环境中的路径；下文相对路径均相对此目录。

只配置用户指定的 Ubuntu。AI Agent 自身的安装、登录和配置不属于初始化步骤，也不安装其他 Skills 或业务服务，不自动整机升级或重启。服务器地址、私钥路径和连接记录不写入本项目。

## 探测与开场对话

在目标环境中先运行 `bash scripts/01-preflight.sh` 确认 Ubuntu、systemd 与执行账号，再用只读命令检查 sudo 能力、主机名、时区、SSH 监听和已有 Git 身份。权限不足或无法确认目标时说明具体缺少的信息；不要先在别处试跑安装。

把原主机名和实际 SSH 端口集合记录为本次会话的验收基线；用户选择保持现状时，最后还要与这份基线比较。sudo 命令存在不等于有提权权限，需实际检查其可用性。

参数默认值与校验共用 `scripts/lib/common.sh`，可执行 `bash scripts/server-init.sh --show-config` 获取。结合现状，在对话中一次收齐尚缺的选择；已提供的信息和授权直接复用。参数与默认行为如下：

| 项目 | 行为 |
|---|---|
| 主机名、SSH 端口 | 用户自定义，留空保持现状；不替用户选择固定 SSH 端口 |
| 时区 | 默认 `Asia/Shanghai`，可自定义或保持现状（空字符串） |
| 管理账号 | 复用普通 sudo 用户，SSH 允许用户名可用逗号分隔 |
| Git 身份 | 复用已有 `user.name` / `user.email`，仅缺失时询问 |
| SSH 加固 | 默认启用；验证公钥登录后关闭密码、键盘交互和 root 登录 |
| fail2ban | 默认启用，跟随实际 SSH 端口 |
| Node、Bun、zsh | 可分别选择，默认不安装 |
| 项目与依赖 | 默认不执行；选择时再收集仓库、目录和环境变量名称 |

开场可这样表达，按已知信息省略问题：

> 我会保留现有主机名和 SSH 端口，时区默认设为 Asia/Shanghai，复用已有 Git 身份，并配置 SSH 公钥登录与 fail2ban。主机名、SSH 端口或时区需要调整吗？Node、Bun、zsh 和项目准备默认跳过，需要的可以一起告诉我。

仅有 root 时，引导用户确定普通管理账号并创建、加入 sudo 组、配置公钥；已有授权和工具能力时由你执行这些准备操作。先取得该账号的新连接与 sudo 验证结果，再关闭 root 登录。用户态工具和 Git 配置应落到选定管理账号的 HOME 下，不要整套套用 sudo 写入 root 的 HOME。

整理并展示最终参数；已有明确选择和执行授权时直接继续。将这些参数贯穿阶段执行与最后验收，不能在重试时悄悄恢复默认值。

## Agent 执行各阶段

使用目标环境的执行工具，按下面顺序调用所需阶段。每个阶段检查退出码与输出，完成后简短说明结果并继续。报错时读取相关输出和 [排错说明](references/troubleshooting.md)，在已授权范围内修复并重试对应阶段；不要把错误当成成功，也不要把排查直接交回用户。

| 阶段 | 由 Agent 调用的工具脚本与参数 |
|---|---|
| 基础依赖 | `bash scripts/02-base-deps.sh --with-ssh yes`；SSH 和 fail2ban 都跳过时传 `no` |
| 主机名、时区 | `bash scripts/02a-system.sh --hostname "$hostname" --timezone "$timezone"`；保留现状传空字符串 |
| 可选 zsh | `bash scripts/02b-zsh.sh --theme "$zsh_theme"` |
| 可选 Node | `bash scripts/03-node.sh --node-version "$node_version" --npm-registry "$npm_registry" --install-bun no` |
| 可选 Bun | `bash scripts/03a-bun.sh` |
| Git 身份 | `bash scripts/05-git-identity.sh --name "$git_name" --email "$git_email"` |
| 可选项目 | `bash scripts/lib/with-env.sh -- bash scripts/06-project.sh --repo "$repo" --dir "$project_dir" --env-keys "$env_keys"` |
| SSH | 按下节的 apply、验证、confirm / rollback 流程执行 |
| fail2ban | `bash scripts/09-fail2ban.sh`，从实际监听读取端口 |
| 完整验收 | `bash scripts/verify-server.sh`，附带与本次请求一致的目标参数 |

表中的变量表示本次已收集的实际值，调用时正确引用和传参。Node 版本、镜像及 zsh 主题等未指定值同样读取共用默认值。Python 辅助程序使用本项目 venv，业务项目依赖使用项目自己的 venv；不退回系统级 pip。项目来源、已有改动、锁文件和 `.env` 保护由阶段脚本检查，失败时处理原因再继续。

`server-init.sh` 保留给独立终端使用，也可用 `--stage prepare --yes` 批量调用普通阶段。使用批量入口时仍由你收集参数、检查结果并继续完成 SSH、fail2ban 和验收；不要启动等待 stdin 的完整交互入口后让用户接管。用户只需参与缺失信息、选择和必须在其客户端完成的连接验证。

## SSH 连接验证与恢复

1. 读取并展示当前实际端口、目标端口或“保持现状”、允许账号和认证设置。可在目标上用 `scripts/lib/common.sh` 的 `init_privilege` 配合 `scripts/lib/ssh-state.sh` 的 `ssh_actual_ports` 获取端口；不能猜测默认端口。
2. 修改前验证普通管理账号的公钥登录和 sudo。修改端口时完成主机防火墙与外部访问规则的放行准备：你可直接处理已有工具权限覆盖的部分，其余由用户完成并确认。已有明确验证结果可复用。
3. 保持原会话，由你执行：

   ```bash
   bash scripts/08-ssh-harden.sh apply \
     --port "$ssh_port" --allow-users "$ssh_allow_users" \
     --permit-root "$ssh_permit_root" --password-auth "$ssh_password_auth" \
     --rollback-after-minutes "$ssh_rollback_minutes"
   bash scripts/08-ssh-harden.sh deadline
   ```

   `ssh_port` 为空即保持现状。脚本会先备份、安排自动回滚，再检查语法、生效配置及监听归属。`deadline` 返回本次回滚截止时间，后续验证以此为准。
4. 修改后建立独立的新连接验证目标账号和 sudo。有能建立独立外部 SSH 连接的工具与授权时，由你执行；否则请用户在另一终端验证并告知结果。两次连接验证都应禁用复用并强制公钥认证，避免 ControlMaster 复用旧会话造成误判。结合当前连接资料提供这一个必要的验证命令，不把普通配置步骤交给用户：

   ```bash
   ssh -S none -o ControlMaster=no -o PreferredAuthentications=publickey \
     -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
     -p <实际端口> <账号>@<服务器>
   ```
   新连接中核对 `whoami` 是目标管理账号，再执行 `sudo -v` 和 `sudo -n id -u`；后者成功输出 `0` 才证明 sudo 可用。仅登录成功不算完成这两项验证。
5. 得到新连接成功的证据且未超时，由你执行 `bash scripts/08-ssh-harden.sh confirm`。失败立即执行 `rollback`；临近截止仍无证据时也回滚，不接受过期确认。若对话暂停或原会话中断，已安排的 `at` 任务负责超时恢复；继续工作前检查实际状态。不得用旧会话仍在线或本地监听成功代替连接验证。
6. 确认或回滚完成后，按选择执行 fail2ban。它使用验证后的实际监听端口，不能手工传入推测值。回滚只代表恢复了原状态，本次请求的 SSH 调整仍应标为未完成。

未确认的 SSH 修改不能再次 apply 覆盖；出现此状态先处理 confirm / rollback。普通服务使用 reload；socket 模式检查主服务 `KillMode=process` 及对应 socket 依赖后同步监听，保留现有会话。不要删除锁或恢复记录绕过检查。

## 验收与交付

由你运行 `scripts/verify-server.sh`（或 `server-init.sh --stage verify`），附带本次实际使用的主机名、时区、SSH 参数、Git 身份、可选组件开关和项目参数。参数名可通过 `server-init.sh --help` 查询。不能遗漏可选开关而将本应完成的项目算作跳过。

主机名或 SSH 端口选择保持现状时，额外读取最终实际值，与开场基线比较；验收脚本对空参数的“跳过”不能代替这项比较。

核对退出码和各项结果，继续处理已授权范围内的失败；确需用户补充时指出具体缺口。最后报告成功、用户跳过、失败和未验证的项目。只有所有必需阶段完成并通过验收，才能宣称初始化完成；项目依赖准备不代表业务已部署或通过业务测试。
