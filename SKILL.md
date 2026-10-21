---
name: server-bootstrap
description: 初始化运行 systemd 的 Ubuntu 服务器，配置基础工具、主机名、时区、Git、SSH 加固和 fail2ban，可选安装 Node、Bun、zsh 或准备项目。适用于新服务器初始化、Ubuntu 装机、VPS 初始化及对应阶段的修复；不用于部署业务服务或管理其他操作系统。
---

# Ubuntu 服务器初始化

用户已连接目标服务器并加载本 Skill。只操作用户当前指定的 Ubuntu 环境，不建立或保存服务器连接资料，不安装助手工具、其他 Skills 或业务服务，不自动整机升级或重启。

默认值、参数解析和校验以 `scripts/lib/common.sh` 为准，统一入口为 `scripts/server-init.sh`。复用阶段脚本，不另写一套安装流程。独立终端使用方式见 [README.md](README.md)；发生错误时按 [排错说明](references/troubleshooting.md) 定位。

## 收集配置

先只读检查当前系统、账号及已有 Git 身份，再集中收齐尚缺的参数。已明确的选择直接复用。可通过下列命令读取统一默认值与参数说明：

```bash
bash scripts/server-init.sh --show-config
bash scripts/server-init.sh --help
```

开场展示以下选择，用户可一次回答：

| 项目 | 默认 |
|---|---|
| 主机名、SSH 端口 | 用户自定义，留空保持现状；不得替用户选择固定 SSH 端口 |
| 时区 | `Asia/Shanghai`；可自定义或保持现状（传空字符串） |
| 管理账号 | 复用普通 sudo 用户；多个 SSH 允许用户以逗号分隔 |
| Git 身份 | 复用现有 `user.name` / `user.email`，仅缺失时询问 |
| SSH 加固 | 启用；公钥登录验证后关闭密码、键盘交互和 root 登录 |
| fail2ban | 启用，使用实际 SSH 端口 |
| Node、Bun、zsh | 均不安装，可分别选择 |
| 项目与依赖 | 不执行；需要时收集仓库地址、目录和环境变量名称 |

仅有 root 时，先引导创建普通管理账号、加入 sudo 组并配置公钥；在另一终端验证登录和 sudo 后再继续。不要凭用户名猜测账号已可登录，也不要收集私钥或把凭据写入项目。

## 执行普通阶段

将用户选择转换成入口支持的参数，先用 `--show-config` 展示完整目标配置。已有授权和明确参数可直接使用，不重复询问。

在项目目录执行 `scripts/server-init.sh --stage prepare --yes`，附带已收集的参数。它共用默认值和阶段脚本，依次检查环境、安装必要基础包、配置系统、按选择安装运行环境、配置 Git、准备可选项目并验收普通阶段。此时 SSH 和 fail2ban 尚未完成。

项目依赖应通过 `scripts/lib/with-env.sh -- <command>` 加载用户态运行环境。Python 辅助程序使用项目专用 venv，业务项目依赖使用各自的 venv；缺少包管理器或安装失败时处理具体错误，不退回系统级 pip。

## SSH 与 fail2ban

SSH 开启时按以下顺序执行。用户跳过 SSH 时直接进入 fail2ban（若启用），其端口仍来自当前实际监听。

1. 展示当前实际监听端口、目标端口或“保持现状”、允许账号和认证设置。让用户先在另一终端验证允许账号的公钥登录与 sudo；修改端口时完成主机防火墙和外部访问规则的放行准备。已有明确验证结果可复用。
2. 保持原 SSH 会话，执行 `scripts/08-ssh-harden.sh apply`，参数映射如下。未提供端口时省略 `--port` 或传 `''`，不要假设当前端口。

   | 入口参数 | SSH 阶段参数 |
   |---|---|
   | `--ssh-port` | `--port` |
   | `--ssh-allow-users` | `--allow-users` |
   | `--ssh-permit-root` | `--permit-root` |
   | `--ssh-password-auth` | `--password-auth` |
   | `--ssh-rollback-minutes` | `--rollback-after-minutes` |

3. 读取 `scripts/08-ssh-harden.sh deadline` 返回的绝对截止时间。要求从第二个终端建立新的公钥连接，验证目标账号及 sudo。不能用旧会话仍在线、`sshd -t` 或监听检查代替新连接验证。两次验证均须禁用连接复用并强制公钥认证，避免 ControlMaster 复用导致误判。按用户自己的连接资料补齐端口、账号和目标：

   ```bash
   ssh -S none -o ControlMaster=no -o PreferredAuthentications=publickey \
     -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
     -p <实际端口> <账号>@<服务器>
   ```
4. 用户确认新连接成功后执行 `scripts/08-ssh-harden.sh confirm`。失败立即执行 `rollback`；未确认且临近截止时间也执行 `rollback`，不接受过期确认。即使当前会话中断，已安排的 `at` 任务仍负责恢复。不得取消自动回滚来省略验证。
5. 启用 fail2ban 时执行 `scripts/09-fail2ban.sh`。它读取实际 SSH 端口，安装所需依赖并验证配置、服务及 sshd jail；不传推测的端口。

SSH 脚本串行化状态变更，拒绝覆盖尚未确认的修改。它检查语法、生效配置、主进程/socket 的监听归属，并核验回滚后的原端口。普通服务使用 reload；socket 模式在检查主服务 `KillMode=process` 及对应 socket 依赖后重启 socket 同步监听，以保留现有会话。遇到冲突先处理当前 `confirm` / `rollback` 状态，不删除锁或恢复记录绕过检查。

## 验收与交付

用与初始化相同的目标参数运行 `scripts/server-init.sh --stage verify`。`--install-node` 等选项必须与实际请求一致，避免把本应完成的项目当成跳过。

报告已完成、用户跳过、失败和未验证的项目；必需项失败或缺少验证证据时不得宣称初始化完成。SSH 回滚成功意味着恢复了原状态，不代表请求的新配置已经完成。项目准备记录只表示依赖阶段成功，不代表业务已部署或通过业务测试。
