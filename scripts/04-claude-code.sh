#!/usr/bin/env bash
# 04-claude-code.sh — 安装 Claude Code CLI（用户态, 无 sudo）
#
# 用法：
#   bash 04-claude-code.sh [--method auto|curl|npm]
#
# 安装方式：
#   - curl: 官方 install.sh → 装到 ~/.local/bin/claude
#   - npm:  npm i -g @anthropic-ai/claude-code → 装到 ~/.nvm/versions/node/<ver>/bin/claude
#   - auto (默认): 先试 curl, 失败（如 claude.ai 返回 403, 中国大陆常见）退回 npm
#
# 已装则跳过, 不重装。

# 不用 -u: nvm.sh 内部某些路径在 set -u 下会挂掉
set -eo pipefail

log()  { printf '\033[1;34m[04-claude-code]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

METHOD="auto"
while [ $# -gt 0 ]; do
  case "$1" in
    --method) METHOD="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--method auto|curl|npm]"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

case "$METHOD" in auto|curl|npm) ;; *) err "--method 必须是 auto/curl/npm"; exit 2 ;; esac

# --- 加载 nvm（npm 路径需要）
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
fi

# --- 把 ~/.local/bin 加进当前进程 PATH（curl 方式装那里）
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# --- 已装则跳过
if command -v claude >/dev/null 2>&1; then
  ok "Claude Code 已装：$(claude --version 2>/dev/null || echo 'version unknown')"
  ok "位置: $(command -v claude)"
  exit 0
fi
if [ -x "$HOME/.local/bin/claude" ]; then
  ok "~/.local/bin/claude 存在: $($HOME/.local/bin/claude --version 2>/dev/null || echo 'version unknown')"
  exit 0
fi

# ---------------------------------------------------------------------------
install_via_curl() {
  log "[curl] 运行官方 install.sh: https://claude.ai/install.sh"
  if curl -fsSL https://claude.ai/install.sh | bash; then
    return 0
  fi
  return 1
}

install_via_npm() {
  if ! command -v npm >/dev/null 2>&1; then
    err "[npm] npm 不可用 — 检查 nvm 是否已装 (phase 03)"
    return 1
  fi
  log "[npm] npm install -g @anthropic-ai/claude-code"
  log "[npm] registry: $(npm config get registry)"
  if npm install -g @anthropic-ai/claude-code; then
    return 0
  fi
  return 1
}
# ---------------------------------------------------------------------------

case "$METHOD" in
  auto)
    if install_via_curl; then
      :
    else
      warn "curl 方式失败（典型原因：claude.ai 在该地区被墙, 返回 HTTP 403）"
      warn "自动退回 npm 方式..."
      if ! install_via_npm; then
        err "curl 和 npm 都失败了"
        err "排错："
        err "  - npm 镜像换国内：npm config set registry https://registry.npmmirror.com"
        err "  - 然后重跑：bash $0 --method npm"
        err "  - 或者 SKILL 调用时传 npm_registry=china"
        exit 1
      fi
    fi
    ;;
  curl)
    install_via_curl || { err "curl 方式失败"; exit 1; }
    ;;
  npm)
    install_via_npm || { err "npm 方式失败"; exit 1; }
    ;;
esac

# --- 校验
if ! command -v claude >/dev/null 2>&1; then
  err "安装命令成功了, 但当前 shell 找不到 claude 命令"
  if [ -x "$HOME/.local/bin/claude" ]; then
    warn "走了 curl 方式: 装在 ~/.local/bin/claude, PATH 可能要 export \$HOME/.local/bin"
  else
    warn "走了 npm 方式: 试 source ~/.nvm/nvm.sh 重新加载 nvm 路径"
  fi
  exit 1
fi

VER="$(claude --version 2>/dev/null || echo 'version unknown')"
ok "Claude Code 安装完成: $VER"
ok "位置: $(command -v claude)"
log "完成（首次使用前在交互终端执行 claude 登录）"
