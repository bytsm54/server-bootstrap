#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
WITH_SSH=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-ssh) [ "$#" -ge 2 ] || exit 2; WITH_SSH="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
valid_yes_no "$WITH_SSH" || exit 2
PKGS=(curl ca-certificates git python3 python3-venv)
[ "$WITH_SSH" != yes ] || PKGS+=(openssh-server iproute2 at util-linux)
MISSING=()
for package in "${PKGS[@]}"; do
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || MISSING+=("$package")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  init_privilege
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${MISSING[@]}"
fi
for package in "${PKGS[@]}"; do
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null)" = 'install ok installed' ] || exit 1
done
. "$SCRIPT_DIR/lib/python-env.sh"
ensure_python_env
printf '基础依赖和 venv 已就绪\n'
