#!/usr/bin/env bash
# Fetch this project and delegate to the standalone initializer.
set -euo pipefail
REPO_URL="${REPO_URL:-https://github.com/bytsm54/server-bootstrap.git}"
REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"
[ -r /etc/os-release ] || { echo '仅支持 Ubuntu' >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = ubuntu ] || { echo '仅支持 Ubuntu' >&2; exit 1; }
if ! command -v git >/dev/null || ! command -v curl >/dev/null; then
  SUDO=(env)
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || { echo '需要 sudo 或 root 安装下载工具' >&2; exit 1; }
    SUDO=(sudo)
  fi
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends git curl ca-certificates
fi
if [ -d "$REPO_DIR/.git" ]; then
  [ "$(git -C "$REPO_DIR" remote get-url origin)" = "$REPO_URL" ] || {
    echo '现有目录的 origin 与 REPO_URL 不一致；请指定另一目录' >&2; exit 1;
  }
  echo '使用现有仓库版本；需要更新时请单独执行 git pull --ff-only'
elif [ -e "$REPO_DIR" ]; then
  echo '目标目录已存在且不是项目仓库' >&2; exit 1
else
  git clone --depth=1 -- "$REPO_URL" "$REPO_DIR"
fi
export REPO_DIR
# curl | bash consumes stdin. The initializer opens /dev/tty for prompts.
exec bash "$REPO_DIR/scripts/server-init.sh" "$@"
