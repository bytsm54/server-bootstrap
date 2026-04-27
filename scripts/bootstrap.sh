#!/usr/bin/env bash
# bootstrap.sh — 零依赖一键入口, 用法：
#   curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
#
# 做什么：
#   1) clone 本仓库到 ~/server-bootstrap（已存在则更新）
#   2) 跑 02-base-deps.sh → 03-node.sh → 04-claude-code.sh
#   3) 打印下一步指引
#
# 不做什么：
#   - 不配 git 身份（phase 05, 在 claude 会话里完成）
#   - 不装项目（phase 06, 可选）
#   - 不装 plugin / skill（phase 07, 可选）
#   - 不动 sshd / 防火墙

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/bytsm54/server-bootstrap.git}"
REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. 必要的最小工具集（curl 自身已经在跑, 这里只确认 git）
if ! command -v git >/dev/null 2>&1; then
  log "git 未安装, 先用 apt 安装 git + curl + ca-certificates"
  if ! command -v sudo >/dev/null 2>&1; then
    die "既没有 git 也没有 sudo, 需要 root / 手动装 git 后重跑"
  fi
  sudo apt-get update -y
  sudo apt-get install -y --no-install-recommends git curl ca-certificates
fi

# --- 2. clone / update 仓库
if [ -d "$REPO_DIR/.git" ]; then
  log "仓库已存在, 拉取最新：$REPO_DIR"
  git -C "$REPO_DIR" fetch --quiet origin
  git -C "$REPO_DIR" pull --ff-only || warn "pull 失败（可能本地有改动）, 继续用当前内容"
else
  log "克隆仓库到 $REPO_DIR"
  git clone --depth=1 "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true

# --- 3. 三个核心 phase
log "Phase 02 — apt 基础依赖"
bash "$REPO_DIR/scripts/02-base-deps.sh"

log "Phase 03 — Node (via nvm, 用户态)"
bash "$REPO_DIR/scripts/03-node.sh" --node-version "${NODE_VERSION:-lts}" --npm-registry "${NPM_REGISTRY:-official}"

log "Phase 04 — Claude Code CLI（用户态, 默认从 GitHub releases 直下二进制, 不经 Cloudflare）"
bash "$REPO_DIR/scripts/04-claude-code.sh" --method "${CLAUDE_INSTALL_METHOD:-auto}" ${CLAUDE_VERSION:+--version "$CLAUDE_VERSION"}

# --- 4. 给出下一步指引（注意：heredoc 不展开 \033 转义, 所以用 printf 输出彩色行）

# 探测当前 claude / node（如果当前 shell 没 source nvm, 这俩可能都找不到, 这是预期）
NODE_VER="(当前 shell 未加载 nvm; 退出重登或 source ~/.nvm/nvm.sh 后可见)"
CLAUDE_VER="(同上)"
[ -s "$HOME/.nvm/nvm.sh" ] && (
  . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
  command -v node >/dev/null 2>&1 && node --version
) >/tmp/.bootstrap-node-ver 2>/dev/null && NODE_VER=$(cat /tmp/.bootstrap-node-ver) && rm -f /tmp/.bootstrap-node-ver
[ -x "$HOME/.local/bin/claude" ] && CLAUDE_VER=$("$HOME/.local/bin/claude" --version 2>/dev/null || echo "已装但无法 --version")

printf '\n\033[1;32m✅ bootstrap.sh 完成\033[0m\n\n'

cat <<EOF
已装：
  - 系统依赖 (apt + at)
  - Node:        $NODE_VER
  - Claude Code: $CLAUDE_VER ($HOME/.local/bin/claude)

EOF

printf '\033[1;33m接下来 (任选一种, 让当前/新 shell 加载 nvm 和 ~/.local/bin):\033[0m\n\n'

cat <<EOF
  ① 推荐：退出再连一次 SSH （新会话会自动加载, 最干净）
       exit
       ssh <user>@<host>
       claude --version    # 应该看到版本号

  ② 当前 shell 替换成 login shell （不用退 SSH, 当前 bash 重启）
       exec bash -l
       claude --version

  ③ 手动 source 一次 （不重启 shell, 立即生效）
       source ~/.nvm/nvm.sh && export PATH="\$HOME/.local/bin:\$PATH"
       claude --version

为什么不能让脚本自动做这一步？
  bootstrap.sh 是你 shell 的子进程, 子进程 export 出来的环境变量
  随子进程退出而消失, 父 shell 拿不到 — 这是 POSIX shell 的根本
  设计, 不是脚本 bug。任何 "curl ... | bash" 模式都有同样限制。

完成上面任一步骤后:

  1) 启动 Claude Code 并登录：
       claude

  2) 在 claude 会话里说：
       "执行 server-bootstrap, git_user_name=Your Name, git_user_email=you@example.com"

     SKILL.md 会走完剩下的 phase
     （02a hostname/timezone, 02b zsh, 05 git 身份, 06 项目克隆,
       07 plugin/skill, 08 SSH 加固, 总检查 — 各 phase 默认行为见 SKILL.md）

  也可以脱离 SKILL 单独跑某个 phase, 例如：
       bash $REPO_DIR/scripts/05-git-identity.sh --name "..." --email "..."
EOF
