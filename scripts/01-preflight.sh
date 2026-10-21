#!/usr/bin/env bash
# Read-only prerequisite checks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
[ -r /etc/os-release ] || { echo '无法读取系统信息' >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = ubuntu ] || { echo '仅支持 Ubuntu' >&2; exit 1; }
command -v apt-get >/dev/null && command -v systemctl >/dev/null || {
  echo '需要 apt 和 systemd 的 Ubuntu 环境' >&2; exit 1;
}
systemctl show --property=Version --value >/dev/null || { echo 'systemd 未运行' >&2; exit 1; }
init_privilege
printf 'Ubuntu: %s; architecture: %s; user: %s\n' "$VERSION_ID" "$(uname -m)" "$(id -un)"
