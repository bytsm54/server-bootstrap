#!/usr/bin/env bash
# 03-node.sh — 安装 nvm 到 ~/.nvm 并通过它装 Node（用户态, 无 sudo）
#
# 用法：
#   bash 03-node.sh [--node-version lts|<ver>] [--npm-registry official|china]
#
# 幂等：
#   - nvm 已装 → 跳过 nvm 安装, 仅按需切版本
#   - 目标 node 版本已装 → 仅 nvm use
#   - 设置/取消 npm 镜像也是幂等的

set -euo pipefail

log()  { printf '\033[1;34m[03-node]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

NODE_VERSION="lts"
NPM_REGISTRY="official"
NVM_INSTALLER_TAG="${NVM_INSTALLER_TAG:-v0.40.3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --node-version) NODE_VERSION="$2"; shift 2 ;;
    --npm-registry) NPM_REGISTRY="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--node-version lts|<ver>] [--npm-registry official|china]"
      exit 0
      ;;
    *)
      err "未知参数: $1"; exit 2 ;;
  esac
done

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# --- 1. 装 nvm（如果没装）
if [ -s "$NVM_DIR/nvm.sh" ]; then
  ok "nvm 已存在 ($NVM_DIR)"
else
  log "安装 nvm $NVM_INSTALLER_TAG 到 $NVM_DIR"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_INSTALLER_TAG/install.sh" | bash
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    err "nvm 安装后 $NVM_DIR/nvm.sh 仍不存在"
    exit 1
  fi
  ok "nvm 安装完成"
fi

# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# --- 2. 装 / 切换 Node
case "$NODE_VERSION" in
  lts|LTS)
    if nvm ls --no-colors | grep -qE 'lts/\* +\->'; then
      ok "Node LTS 已装"
    else
      log "nvm install --lts"
      nvm install --lts
    fi
    nvm use --lts >/dev/null
    nvm alias default 'lts/*' >/dev/null || true
    ;;
  *)
    if nvm ls --no-colors | grep -qE "v?$NODE_VERSION([^0-9]|\$)"; then
      ok "Node $NODE_VERSION 已装"
    else
      log "nvm install $NODE_VERSION"
      nvm install "$NODE_VERSION"
    fi
    nvm use "$NODE_VERSION" >/dev/null
    nvm alias default "$NODE_VERSION" >/dev/null || true
    ;;
esac

ok "Node: $(node --version)"
ok "npm:  $(npm --version)"
ok "npx:  $(npx --version)"

# --- 3. npm 镜像
case "$NPM_REGISTRY" in
  china)
    log "切换 npm registry → npmmirror.com"
    npm config set registry https://registry.npmmirror.com
    ;;
  official|"")
    if [ "$(npm config get registry)" != "https://registry.npmjs.org/" ]; then
      log "重置 npm registry → 官方"
      npm config delete registry || true
    fi
    ;;
  *)
    err "--npm-registry 必须是 official 或 china（你给了 $NPM_REGISTRY）"
    exit 2
    ;;
esac

ok "registry: $(npm config get registry)"
log "完成"
