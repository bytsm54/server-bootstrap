# Troubleshooting

按"症状"快速跳。

## 1. `command not found: node` / `npm` / `claude`（在 Claude Code 的 Bash tool 里）

**原因**：Claude Code 的 `Bash` 工具每次起新 bash 子进程, **不会** 自动 source 你的 `~/.zshrc` 或 `~/.bashrc`, 所以 nvm 不会自动加载, `~/.local/bin` 也可能不在 PATH 里。

**解决**：把命令套上 `with-env.sh`：

```bash
bash ~/server-bootstrap/scripts/lib/with-env.sh -- claude --version
bash ~/server-bootstrap/scripts/lib/with-env.sh -- npm install -g something
bash ~/server-bootstrap/scripts/lib/with-env.sh -- bash ~/server-bootstrap/scripts/05-git-identity.sh --name a --email b@c.com
```

或手动 source：
```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="$HOME/.local/bin:$PATH"
```

如果你是在普通 SSH 终端里, 重新登录 / 开个新 shell 一般就好（rc 文件被自动加载）。

---

## 2. `02-base-deps.sh` 提示需要 sudo, 但服务器没装 sudo

**情况 A：你是 root**
直接以 root 跑就好, 脚本会跳过 `sudo` 调用：
```bash
bash ~/server-bootstrap/scripts/02-base-deps.sh
```

**情况 B：你是普通用户但没 sudo**
让 root 帮你装：
```bash
su -
apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git build-essential sudo
usermod -aG sudo your-user   # 可选
exit
```
然后回到普通用户身份重跑后续 phase。

---

## 3. `git clone` 失败：`Could not resolve host: github.com`

网络问题。检查：
```bash
ping -c 2 8.8.8.8        # 网络通吗
ping -c 2 github.com     # DNS 通吗
curl -I https://github.com  # HTTPS 通吗
```

国内服务器经常需要镜像或代理。临时方案：
```bash
# 用 GitHub 镜像代替（仅作 clone 用）
export REPO_URL=https://gh-proxy.com/https://github.com/bytsm54/server-bootstrap.git
bash <(curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh)
```

---

## 3b. `bootstrap.sh` 跑到 phase 03 报 `PROVIDED_VERSION: unbound variable`

这是 nvm 在严格模式 (`set -u`) 下的已知问题——nvm.sh 内部少数代码路径会引用未初始化变量。本仓库 ≥ commit 修复后已经移除 `-u`, 如果你看到这个错, 多半是你跑的是旧版 bootstrap.sh。

恢复方法（不需要等修复）：
```bash
source ~/.nvm/nvm.sh         # 当前 shell 加载 nvm
node -v                      # 应该有版本号
bash ~/server-bootstrap/scripts/04-claude-code.sh
export PATH="$HOME/.local/bin:$PATH"
claude --version
```

或者拉最新仓库再跑一次 bootstrap.sh（幂等）：
```bash
git -C ~/server-bootstrap pull --ff-only
bash ~/server-bootstrap/scripts/bootstrap.sh
```

---

## 3c. Claude Code 安装时 curl 报 `error 403`（中国大陆典型）

```
[04-claude-code] 运行官方 install.sh
curl: (22) The requested URL returned error: 403
```

**原因**：`claude.ai` 在中国大陆地区被 Anthropic / Cloudflare 限流, 直接访问会返回 403。

**自动恢复**（拉新版后重跑）：
```bash
git -C ~/server-bootstrap pull --ff-only
bash ~/server-bootstrap/scripts/bootstrap.sh
```
04-claude-code.sh 现在默认 `--method auto`：curl 失败会自动退回 `npm install -g @anthropic-ai/claude-code`。

**手动恢复**（不想等重跑）：
```bash
source ~/.nvm/nvm.sh
# 如果 npm 官方源也慢, 先切镜像:
npm config set registry https://registry.npmmirror.com
npm install -g @anthropic-ai/claude-code
claude --version
```

**长期建议**：在中国大陆服务器调用本 skill 时, 加上参数：
```
npm_registry=china, claude_install_method=npm
```
这样直接走 npm 镜像, 避开 curl 的 403。

---

## 4. nvm 装完了, 但 `nvm` 命令不存在

**原因**：nvm 装到 `~/.nvm`, 通过 source `~/.nvm/nvm.sh` 加载到 shell function 里, 不是真正的可执行文件。
- 新 shell 通过 `~/.zshrc` / `~/.bashrc` 自动 source（nvm 安装时已写入）
- 当前 shell 需要手动 source 一次：
  ```bash
  . ~/.nvm/nvm.sh
  ```

如果 rc 文件没被改, 看 `~/.bashrc` 末尾是否有 nvm 相关行；没有就手动加：
```bash
cat >> ~/.bashrc <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
EOF
```

---

## 5. Claude Code 装好了, 但 `claude` 启动后白屏 / 卡住

- 第一次启动需要登录, 走浏览器 OAuth 流程。如果你在纯命令行服务器（无 GUI）上, 它会给你一个 URL, 复制到你**本地**浏览器里完成登录, 然后把回调 token 粘回服务器终端。
- 如果连 URL 都没看到, 可能是你被 stdout 缓冲住了。重新开一个终端, 跑 `claude` 即可。

---

## 6. 重跑某个 phase 出错（说"已存在"或类似）

所有 phase 都设计成幂等的。如果你看到 conflict / "already exists" 类错误：

| Phase | 已存在状态 | 期望行为 |
|---|---|---|
| 02 | 包已装 | 跳过整个 phase |
| 03 | nvm 已装、Node 版本已装 | 跳过安装, 仅 `nvm use` |
| 04 | claude 已在 PATH | 跳过, 不重装 |
| 05 | name/email 已是目标值 | 跳过 |
| 06 | 项目目录已是 git 仓库 | `git pull --ff-only` |
| 07 | plugin / skill 已装 | claude / npx 自身会报"已存在", 退出码非 0；脚本设计成"失败也继续下一个" |

如果某个 phase 因为状态冲突彻底卡住, 最干净的办法是**从 0 开始**：
```bash
# 想重置 nvm（小心：会丢所有装过的 Node 版本和全局 npm 包）
rm -rf ~/.nvm
# 想重置 Claude Code（用户态, 不需要 sudo）
rm -rf ~/.local/bin/claude ~/.config/claude
```

---

## 7. `npx skills add` 报 401 / 403

`skills` CLI 拉的是 GitHub 仓库, 401/403 通常是：
- 仓库是 private, 你没认证 → 改用 public, 或先 `gh auth login`
- 仓库不存在 / 拼错

---

## 8. SSH 加固完, 新端口登不上 / 锁出去了

### 你还连着旧 SSH 会话（最常见, 最好处理）
什么都别做, 等 deadman 自动回滚（默认 5 分钟内）。窗口期内你也可以手动：
```bash
bash ~/server-bootstrap/scripts/08-ssh-harden.sh rollback
```
回滚后 sshd 回到加固前的状态, 旧连接和旧端口又能用了。

### 你已经断线了（但 deadman 还没触发）
- **如果 deadman 设了**：等到 `--rollback-after-minutes` 分钟（默认 5）后再试旧端口, 应该能连上。
- **如果你跑了 `--no-deadman`**：你需要带外访问（云厂商 console / 物理键盘 / IPMI）。进系统后：
  ```bash
  sudo bash ~/server-bootstrap/scripts/08-ssh-harden.sh rollback
  ```

### 云防火墙 / 安全组没放新端口（最常见低级失误）
sshd 在新端口 listen 了, 但云防火墙没放行 → 包到不了。先去云控制台：
- AWS: EC2 → Security Groups → Inbound rules → Add rule (TCP, 你的新端口)
- 阿里云: 安全组 → 入方向规则
- 腾讯云: 安全组 → 入站规则
- GCP: VPC firewall rules

加好规则后重试 `ssh -p <新端口> ...`。

### 还是不行, 想完全恢复成「加固前」
```bash
# 找最近的备份
sudo ls -1t /var/backups/sshd-bootstrap/sshd-*.tar.gz | head
# 解开
sudo tar xzf /var/backups/sshd-bootstrap/sshd-<时间戳>.tar.gz -C /
# 校验 + 重载
sudo sshd -t && sudo systemctl reload sshd
```

---

## 9. zsh 装好了但提示 `command not found: <something>`
oh-my-zsh 装好后默认 plugin 列表只有 git。02b-zsh.sh 会自动追加 sudo / zsh-syntax-highlighting / zsh-autosuggestions, 但前提是 ~/.zshrc 有 `plugins=(...)` 那一行。如果你看到插件没生效：
1. 看 `~/.zshrc` 里的 `plugins=` 行内容
2. 缺啥补啥, 例如：
   ```bash
   plugins=(git sudo zsh-syntax-highlighting zsh-autosuggestions)
   ```
3. 重新 source: `source ~/.zshrc`

如果你的 nvm 加载失效（升级 oh-my-zsh 后偶尔会发生）：检查 ~/.zshrc 末尾是不是少了：
```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
```

---

## 10. 我想在 *别的* 机器上重新跑一次, 完全一致

只要：
```bash
ssh new-server
curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
claude   # 登录
# 进 claude 会话, 说："执行 server-bootstrap"
```
本 skill 的全部输入参数都通过参数列表传入, 不依赖任何隐藏的环境变量, 所以同样输入下行为是一致的。
