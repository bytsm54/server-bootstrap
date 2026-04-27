#!/usr/bin/env bash
# 01-preflight.sh — 环境检测：OS、网络、sudo 是否可用
# 不改任何东西, 只打印 + 返回码。
#   0  全部 OK 或仅 warn
#   1  fatal（OS 不支持或网络完全不通）

set -euo pipefail

log()  { printf '\033[1;34m[01-preflight]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*"; }

FATAL=0

# --- 1. OS
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-unknown}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:*debian*|*:*ubuntu*)
      ok "OS: ${PRETTY_NAME:-$ID $VERSION_ID}"
      ;;
    *)
      err "OS 不是 Debian / Ubuntu 系：ID=${ID:-?} ID_LIKE=${ID_LIKE:-?}"
      err "本 skill 只支持 apt 系发行版"
      FATAL=1
      ;;
  esac
else
  err "/etc/os-release 不存在, 无法判断 OS"
  FATAL=1
fi

# --- 2. 架构
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|aarch64|arm64) ok "架构: $ARCH" ;;
  *) warn "架构 $ARCH 非主流, nvm / Claude Code 可能无预编译二进制" ;;
esac

# --- 3. sudo 可用性
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    ok "sudo 可用（免密）"
  else
    warn "sudo 已安装, 但需要密码（apt 安装时会交互）"
  fi
else
  warn "sudo 未安装。如果你不是 root, 02-base-deps 会失败"
  if [ "$(id -u)" = "0" ]; then
    ok "当前是 root, 无需 sudo"
  fi
fi

# --- 4. 网络（GitHub / npm / Anthropic）
check_url() {
  local url="$1" name="$2"
  if curl -fsSL --max-time 8 -o /dev/null -I "$url" 2>/dev/null; then
    ok "可访问 $name ($url)"
  else
    warn "访问 $name 失败 ($url) — 可能要走镜像 / 代理"
  fi
}

if command -v curl >/dev/null 2>&1; then
  check_url "https://github.com"          "GitHub"
  check_url "https://registry.npmjs.org"  "npm 官方"
  check_url "https://claude.ai"           "Claude"
else
  warn "curl 未安装, 跳过网络探测（02-base-deps 会装上）"
fi

# --- 5. 已存在的关键工具（用于 03/04 的幂等判断, 这里只是预报）
for tool in git curl ca-certificates build-essential; do
  case "$tool" in
    git|curl) command -v "$tool" >/dev/null 2>&1 && ok "$tool 已装" || warn "$tool 未装" ;;
    *)        dpkg -s "$tool" >/dev/null 2>&1   && ok "$tool 已装" || warn "$tool 未装" ;;
  esac
done

if [ -d "$HOME/.nvm" ]; then ok "nvm 已存在 ($HOME/.nvm)"; else warn "nvm 未装"; fi
if command -v claude >/dev/null 2>&1 || [ -x "$HOME/.local/bin/claude" ]; then
  ok "Claude Code 已存在"
else
  warn "Claude Code 未装"
fi

# --- 总结
echo
if [ "$FATAL" -ne 0 ]; then
  err "preflight 发现 fatal 问题, 终止"
  exit 1
fi
log "preflight 通过"
