#!/usr/bin/env bash
# Read-only diagnostics. Connectivity failures are warnings; privileges are required.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
for arg in "$@"; do
  case "$arg" in -h|--help) echo 'Usage: 01-preflight.sh [server-init options describing selected features]'; exit 0 ;; esac
done
config_defaults
parse_config "$@"
validate_config
[ -r /etc/os-release ] || { echo '无法读取系统信息' >&2; exit 1; }
. /etc/os-release
[ "${ID:-}" = ubuntu ] || { echo '仅支持 Ubuntu' >&2; exit 1; }
command -v apt-get >/dev/null && command -v systemctl >/dev/null || {
  echo '需要 apt 和 systemd 的 Ubuntu 环境' >&2; exit 1;
}
FAILED=0
if ! systemctl show --property=Version --value >/dev/null; then
  echo '无法访问 systemd；检查执行环境或沙箱权限，不能据此判定宿主机损坏' >&2
  FAILED=1
fi
init_privilege noninteractive
if [ "$("${SUDO[@]}" id -u 2>/dev/null || true)" != 0 ]; then
  if grep -Eq '^NoNewPrivs:[[:space:]]+1$' /proc/self/status; then
    echo '当前执行环境设置了 no new privileges，无法通过 sudo 提权；需要策略允许的主机执行通道' >&2
  else
    echo 'sudo 实际提权未通过；检查授权，需密码时在同一交互终端完成认证后重试' >&2
  fi
  FAILED=1
fi
printf 'Ubuntu: %s; architecture: %s; user: %s\n' "$VERSION_ID" "$(uname -m)" "$(id -un)"
for tool in git curl python3 zsh node npm bun uv pnpm yarn; do
  printf '工具 %-8s %s\n' "$tool" "$(command -v "$tool" || echo 未发现)"
done
for package in python3-venv build-essential; do
  printf '软件包 %s: %s\n' "$package" "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || echo 未安装)"
done
if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then echo 'nvm: 已存在'; else echo 'nvm: 未发现'; fi
URLS=()
if [ "$INSTALL_ZSH" = yes ] || [ "$INSTALL_BUN" = yes ]; then URLS+=(https://github.com); fi
if [ "$INSTALL_NODE" = yes ]; then
  if [ "$NPM_REGISTRY" = china ]; then URLS+=(https://gitee.com https://npmmirror.com/mirrors/node/index.tab https://registry.npmmirror.com)
  else URLS+=(https://github.com https://nodejs.org/dist/index.tab https://registry.npmjs.org); fi
fi
if [ -n "$PROJECT_REPO" ]; then echo '项目依赖源将在读取清单后检查；Git SSH 来源以实际 clone 结果为准'; fi
if command -v curl >/dev/null; then
  for url in ${URLS[@]+"${URLS[@]}"}; do
    if curl -fsSL --connect-timeout 5 --max-time 10 -o /dev/null "$url"; then printf '[可访问] %s\n' "$url"
    else printf '[提示] 无法访问 %s；所选功能下载时可能需要调整网络或来源\n' "$url" >&2; fi
  done
else echo '[提示] curl 尚未安装，网络检查跳过；基础依赖阶段会安装'; fi
[ "$FAILED" -eq 0 ]
