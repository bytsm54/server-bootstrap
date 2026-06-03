#!/usr/bin/env bash
# 04-claude-code.sh — 安装 Claude Code CLI（用户态, 无 sudo）
#
# 用法：
#   bash 04-claude-code.sh [--method auto|github|curl] [--version vX.Y.Z]
#
# 安装方式：
#   github (默认且推荐): 直接从 anthropics/claude-code GitHub releases 下载二进制
#                       tarball, 校验 SHA256, 解压到 ~/.local/bin/claude
#                       — 不经 Cloudflare, 任何地区都能装
#
#   curl              : 走 https://claude.ai/install.sh
#                       — 中国大陆 / Cloudflare 限流地区会 HTTP 403
#
#   auto              : 先 github, 失败再退到 curl
#
# 已装则跳过, 不重装。npm 方式已被 Anthropic 弃用（deprecated）, 本脚本不再提供。

# 不用 -u: 兼容（与其他 phase 保持风格一致）
set -eo pipefail

log()  { printf '\033[1;34m[04-claude-code]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

METHOD="auto"
VERSION_PIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --method)  METHOD="$2"; shift 2 ;;
    --version) VERSION_PIN="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"; exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done
case "$METHOD" in auto|github|curl) ;; *) err "--method 必须是 auto/github/curl"; exit 2 ;; esac

# ~/.local/bin → 当前 PATH
mkdir -p "$HOME/.local/bin"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# 只信任 bootstrap 管理的位置; 其他 PATH 里的 claude 不能让本 phase 跳过。
if [ -x "$HOME/.local/bin/claude" ] && [ "$(command -v claude 2>/dev/null || true)" = "$HOME/.local/bin/claude" ]; then
  ok "Claude Code 已装：$(claude --version 2>/dev/null || echo 'version unknown')"
  ok "位置: $(command -v claude)"
  exit 0
fi
[ -L "$HOME/.local/bin/claude" ] && rm -f "$HOME/.local/bin/claude"

# --- 临时目录与清理
TMP_DIR=""
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
install_via_github() {
  # 1. 检测平台
  local arch libc asset tag asset_url sha_url
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)   arch=x64   ;;
    aarch64|arm64)  arch=arm64 ;;
    *) err "[github] 不支持的架构: $arch"; return 1 ;;
  esac

  libc=""
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    libc="-musl"
    log "[github] 检测到 musl libc, 使用 musl 资产"
  fi
  asset="claude-linux-${arch}${libc}.tar.gz"

  # 2. 决定版本
  if [ -n "$VERSION_PIN" ]; then
    tag="$VERSION_PIN"
    log "[github] 使用指定版本: $tag"
  else
    log "[github] 查询最新版本 (api.github.com)"
    tag="$(curl -fsSL https://api.github.com/repos/anthropics/claude-code/releases/latest 2>/dev/null \
           | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
    if [ -z "$tag" ]; then
      err "[github] 解析 latest tag 失败（可能 GitHub API 限流, 或 python3 不可用）"
      err "  退路：CLAUDE_VERSION=vX.Y.Z 显式指定, 或重试"
      return 1
    fi
  fi
  log "[github] 版本=$tag, 资产=$asset"

  asset_url="https://github.com/anthropics/claude-code/releases/download/${tag}/${asset}"
  sha_url="https://github.com/anthropics/claude-code/releases/download/${tag}/SHASUMS256.txt"

  # 3. 下载 + 校验
  TMP_DIR="$(mktemp -d)"
  log "[github] 下载到 $TMP_DIR"
  if ! curl -fsSL --retry 3 -o "$TMP_DIR/$asset" "$asset_url"; then
    err "[github] 下载 $asset 失败 ($asset_url)"
    return 1
  fi

  if curl -fsSL --retry 3 -o "$TMP_DIR/SHASUMS256.txt" "$sha_url" 2>/dev/null; then
    if grep -q " ${asset}\$" "$TMP_DIR/SHASUMS256.txt"; then
      ( cd "$TMP_DIR" && grep " ${asset}\$" SHASUMS256.txt | sha256sum -c - >/dev/null ) \
        && ok "[github] SHA256 校验通过" \
        || { err "[github] SHA256 校验失败！下载受损或被篡改, 拒绝继续"; return 1; }
    else
      warn "[github] SHASUMS256.txt 中无 $asset 条目, 跳过校验"
    fi
  else
    warn "[github] 拿不到 SHASUMS256.txt, 跳过校验（不推荐）"
  fi

  # 4. 解压并安装
  ( cd "$TMP_DIR" && tar -xzf "$asset" )
  local bin
  bin="$(find "$TMP_DIR" -maxdepth 3 -name claude -type f -executable 2>/dev/null | head -1)"
  if [ -z "$bin" ] || [ ! -f "$bin" ]; then
    err "[github] 解压后找不到 claude 可执行文件"
    return 1
  fi

  install -m 0755 "$bin" "$HOME/.local/bin/claude"
  ok "[github] 已安装到 ~/.local/bin/claude"
  return 0
}

install_via_curl() {
  log "[curl] 运行官方 install.sh: https://claude.ai/install.sh"
  log "[curl] 注意: claude.ai 在中国大陆 / 部分 Cloudflare 限流地区会 403"
  if curl -fsSL https://claude.ai/install.sh | bash; then
    return 0
  fi
  return 1
}
# ---------------------------------------------------------------------------

case "$METHOD" in
  auto)
    if install_via_github; then
      :
    else
      warn "[github] 失败, 退到 [curl] 兜底"
      install_via_curl || { err "github + curl 全部失败"; exit 1; }
    fi
    ;;
  github)
    install_via_github || exit 1
    ;;
  curl)
    install_via_curl || exit 1
    ;;
esac

# 校验
if ! command -v claude >/dev/null 2>&1; then
  err "安装命令成功了, 但当前 shell 找不到 claude"
  err "试 export PATH=\"\$HOME/.local/bin:\$PATH\" 后 hash -r"
  exit 1
fi

VER="$(claude --version 2>/dev/null || echo 'version unknown')"
ok "Claude Code 安装完成: $VER"
ok "位置: $(command -v claude)"
log "完成（首次使用前在交互终端执行 claude 来登录）"
