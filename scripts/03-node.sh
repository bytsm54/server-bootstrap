#!/usr/bin/env bash
# 03-node.sh — 安装 nvm 到 ~/.nvm 并通过它装 Node（用户态, 无 sudo）
#
# 用法：
#   bash 03-node.sh [--node-version lts|<ver>] [--npm-registry official|china] [--install-bun yes|no]
#
# 幂等：
#   - nvm 已装 → 跳过 nvm 安装, 仅按需切版本
#   - 目标 node 版本已装 → 仅 nvm use
#   - 设置/取消 npm 镜像也是幂等的

# 注意：故意不用 -u（set -u）。nvm 内部有代码路径引用未初始化的 PROVIDED_VERSION
# 等变量, 在 -u 下会触发 "unbound variable" 中断 nvm install。这是 nvm 已知的兼容
# 性问题（见 nvm-sh/nvm 多个 issue）。我们仍保留 -e 和 -o pipefail。
set -eo pipefail

log()  { printf '\033[1;34m[03-node]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/toolchain.sh
. "$SCRIPT_DIR/lib/toolchain.sh"

NODE_VERSION="lts"
NPM_REGISTRY="china"
INSTALL_BUN="no"
# These values bind both mirror and upstream installs to the reviewed nvm release.
# Update the tag and peeled tag commit together.
NVM_INSTALLER_TAG="${NVM_INSTALLER_TAG:-v0.40.3}"
NVM_EXPECTED_COMMIT="${NVM_EXPECTED_COMMIT:-977563e97ddc66facf3a8e31c6cff01d236f09bd}"

while [ $# -gt 0 ]; do
  case "$1" in
    --node-version) NODE_VERSION="$2"; shift 2 ;;
    --npm-registry) NPM_REGISTRY="$2"; shift 2 ;;
    --install-bun) INSTALL_BUN="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--node-version lts|<ver>] [--npm-registry official|china] [--install-bun yes|no]"
      exit 0
      ;;
    *)
      err "未知参数: $1"; exit 2 ;;
  esac
done

[[ "$NODE_VERSION" = lts || "$NODE_VERSION" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]] || { err "Node version 无效"; exit 2; }

case "$INSTALL_BUN" in
  yes|no) ;;
  *) err "--install-bun 必须是 yes 或 no"; exit 2 ;;
esac

case "$NPM_REGISTRY" in
  china)
    NVM_REPOSITORY_URL="${NVM_SOURCE:-https://gitee.com/mirrors/nvm.git}"
    export NVM_NODEJS_ORG_MIRROR="${NVM_NODEJS_ORG_MIRROR:-https://npmmirror.com/mirrors/node}"
    ;;
  official|"")
    export NVM_NODEJS_ORG_MIRROR="https://nodejs.org/dist"
    NVM_REPOSITORY_URL="${NVM_SOURCE:-https://github.com/nvm-sh/nvm.git}"
    ;;
  *)
    err "--npm-registry 必须是 official 或 china（你给了 $NPM_REGISTRY）"
    exit 2
    ;;
esac

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# --- 1. 装 nvm（如果没装）
if [ -s "$NVM_DIR/nvm.sh" ]; then
  ok "nvm 已存在 ($NVM_DIR)"
else
  NVM_PARENT_DIR="$(dirname "$NVM_DIR")"
  mkdir -p "$NVM_PARENT_DIR"
  NVM_STAGING_DIR="$(mktemp -d "$NVM_PARENT_DIR/.nvm-staging.XXXXXX")"
  log "安装 nvm $NVM_INSTALLER_TAG 到 $NVM_DIR"
  if ! git clone --quiet --depth=1 --branch "$NVM_INSTALLER_TAG" \
    "$NVM_REPOSITORY_URL" "$NVM_STAGING_DIR"; then
    rm -rf -- "$NVM_STAGING_DIR"
    err "nvm 仓库下载失败: $NVM_REPOSITORY_URL"
    exit 1
  fi
  NVM_ACTUAL_COMMIT="$(git -C "$NVM_STAGING_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ "$NVM_ACTUAL_COMMIT" != "$NVM_EXPECTED_COMMIT" ]; then
    err "nvm commit 校验失败，未验证目录保留在 $NVM_STAGING_DIR"
    err "期望: $NVM_EXPECTED_COMMIT"
    err "实际: ${NVM_ACTUAL_COMMIT:-unknown}"
    exit 1
  fi
  if [ ! -s "$NVM_STAGING_DIR/nvm.sh" ]; then
    err "已验证的 nvm 仓库缺少 nvm.sh，目录保留在 $NVM_STAGING_DIR"
    exit 1
  fi
  if [ -e "$NVM_DIR" ]; then
    rm -rf -- "$NVM_STAGING_DIR"
    err "$NVM_DIR 已存在但 nvm.sh 不完整，请先移走该目录后重跑"
    exit 1
  fi
  mv "$NVM_STAGING_DIR" "$NVM_DIR"
  ok "nvm 安装完成"
fi

# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# Resolve against installed versions, not the presence of an LTS alias in `nvm ls`.
if [[ "$NODE_VERSION" = lts || "$NODE_VERSION" = LTS ]]; then
  RESOLVED="$(nvm version 'lts/*' 2>/dev/null || true)"
  if [ "$RESOLVED" = N/A ] || [ -z "$RESOLVED" ]; then nvm install --lts; fi
  nvm use --lts >/dev/null
  nvm alias default "$(node --version)" >/dev/null
else
  [[ "$NODE_VERSION" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]] || { err "Node version 无效"; exit 2; }
  RESOLVED="$(nvm version "$NODE_VERSION" 2>/dev/null || true)"
  if [ "$RESOLVED" = N/A ] || [ -z "$RESOLVED" ]; then nvm install "$NODE_VERSION"; fi
  nvm use "$NODE_VERSION" >/dev/null
  nvm alias default "$(node --version)" >/dev/null
fi

ok "Node: $(node --version)"
ok "npm:  $(npm --version)"
ok "npx:  $(npx --version)"

NVM_NODE_BIN="$(dirname "$(command -v node)")"
ensure_managed_node_toolchain "$NVM_NODE_BIN"
ok "Node toolchain path: $NVM_NODE_BIN"

# --- 3. npm 镜像
case "$NPM_REGISTRY" in
  china)
    log "切换 npm registry → npmmirror.com"
    npm config set registry https://registry.npmmirror.com
    ;;
  official|"")
    if [ "$(npm config get registry)" != "https://registry.npmjs.org/" ]; then
      log "重置 npm registry → 官方"
      npm config set registry https://registry.npmjs.org/
    fi
    ;;
  *)
    err "--npm-registry 必须是 official 或 china（你给了 $NPM_REGISTRY）"
    exit 2
    ;;
esac

ok "registry: $(npm config get registry)"

# Write bounded configuration blocks using the project helper venv.
. "$SCRIPT_DIR/lib/python-env.sh"
ensure_python_env
for rc in .bashrc .zshrc; do
  printf 'export NVM_DIR=%q\n[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n' "$NVM_DIR" | \
    "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$HOME/$rc" nvm-load
done
for rc in .profile .bashrc .zshrc; do
  cat <<'EOF' | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$HOME/$rc" localbin-path
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$PATH:$HOME/.local/bin" ;; esac
EOF
done
if [ "$INSTALL_BUN" = yes ]; then bash "$SCRIPT_DIR/03a-bun.sh"; fi
log "完成"
