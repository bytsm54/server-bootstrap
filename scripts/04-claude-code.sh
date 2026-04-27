#!/usr/bin/env bash
# 04-claude-code.sh — 安装 Claude Code CLI（用户态）
#
# 默认走官方 install.sh 装到 ~/.local/bin。
# 已装则只校验版本, 不重装。
# 不会自动登录（claude 登录是交互的, 让用户自己跑 `claude` 一次）。

set -euo pipefail

log()  { printf '\033[1;34m[04-claude-code]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

# 把 ~/.local/bin 加进当前进程 PATH
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# --- 已装则检测 + 退出
if command -v claude >/dev/null 2>&1; then
  CUR="$(claude --version 2>/dev/null || true)"
  ok "Claude Code 已装：${CUR:-version unknown}"
  log "如需更新, 重跑官方 install.sh 即可"
  exit 0
fi

if [ -x "$HOME/.local/bin/claude" ]; then
  ok "找到 ~/.local/bin/claude（PATH 当前未含, 已加上）"
  ok "$($HOME/.local/bin/claude --version 2>/dev/null || echo 'version unknown')"
  exit 0
fi

# --- 安装
log "运行官方 install.sh（用户态, 默认 ~/.local/bin）"
if ! curl -fsSL https://claude.ai/install.sh | bash; then
  err "Claude Code install.sh 失败"
  err "排错思路：检查网络访问 claude.ai, 检查 ~/.local 是否可写"
  exit 1
fi

# 确认结果
if ! command -v claude >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/claude" ]; then
    warn "claude 装到了 $HOME/.local/bin/claude, 但当前 PATH 不含此目录"
    warn "新 shell 会通过 install.sh 写入的 rc 自动生效, 但当前 shell 需要："
    warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  else
    err "安装完成后仍找不到 claude 二进制"
    exit 1
  fi
fi

VER="$(claude --version 2>/dev/null || $HOME/.local/bin/claude --version 2>/dev/null || echo 'version unknown')"
ok "Claude Code 安装完成：$VER"
log "完成（首次使用前请在交互终端执行：claude  来登录）"
