#!/usr/bin/env bash
# verify-server.sh — pure server initialization summary

# Keep checking after missing optional or required components.
# nvm.sh is not safe under set -u because it uses unset variables internally.
set -o pipefail

ok()   { printf '  ✅ %s\n' "$*"; }
miss() { printf '  ❌ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/toolchain.sh
. "$SCRIPT_DIR/lib/toolchain.sh"

echo "=========================="
echo " server initialization verify"
echo "=========================="

HOST="$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || echo '?')"
TZ_NOW="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
ok "hostname:   $HOST"
ok "timezone:   $TZ_NOW ($(date '+%Y-%m-%d %H:%M:%S %z'))"

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null
path_append_once "$HOME/.local/bin"

if command -v node >/dev/null 2>&1; then
  ok "Node:       $(node --version) ($(command -v node))"
else
  miss "Node:       未找到（试 source ~/.nvm/nvm.sh 或用 with-env.sh 包装）"
fi

if command -v npm >/dev/null 2>&1; then
  ok "npm:        $(npm --version) ($(command -v npm))  prefix=$(npm prefix -g) registry=$(npm config get registry)"
else
  miss "npm:        未找到"
fi

if command -v node >/dev/null 2>&1; then
  NVM_NODE_BIN="$(dirname "$(command -v node)")"
  for tool in node npm npx; do
    LOCAL_TOOL="$HOME/.local/bin/$tool"
    if [ -e "$LOCAL_TOOL" ]; then
      miss "Toolchain:  $LOCAL_TOOL shadows managed nvm $tool"
    elif [ "$(command -v "$tool" 2>/dev/null || true)" = "$NVM_NODE_BIN/$tool" ]; then
      ok "Toolchain:  $tool uses managed nvm path"
    else
      warn "Toolchain:  $tool path is $(command -v "$tool" 2>/dev/null || echo '?')"
    fi
  done
fi

if [ -x "$HOME/.bun/bin/bun" ]; then
  ok "Bun:        $("$HOME/.bun/bin/bun" --version) ($HOME/.bun/bin/bun)"
elif command -v bun >/dev/null 2>&1; then
  ok "Bun:        $(bun --version) ($(command -v bun))"
fi

GN="$(git config --global user.name 2>/dev/null || true)"
GE="$(git config --global user.email 2>/dev/null || true)"
GB="$(git config --global init.defaultBranch 2>/dev/null || true)"
if [ -n "$GN" ] && [ -n "$GE" ]; then
  ok "git:        $GN <$GE>"
else
  miss "git:        全局身份未配置（跑 05-git-identity.sh）"
fi
[ -z "$GB" ] || ok "git branch: $GB"

if command -v zsh >/dev/null 2>&1; then
  USER_SHELL="$(getent passwd "$(id -un)" | cut -d: -f7)"
  if [ "$USER_SHELL" = "$(command -v zsh)" ]; then
    ok "zsh:        $(zsh --version | awk '{print $2}') (默认 shell)"
  else
    ok "zsh:        $(zsh --version | awk '{print $2}') (非默认, 默认是 $USER_SHELL)"
  fi
  if [ -f "$HOME/.zshrc" ] && grep -qE '^ZSH_THEME=' "$HOME/.zshrc"; then
    THEME="$(grep -m1 -E '^ZSH_THEME=' "$HOME/.zshrc" | sed -E 's/^ZSH_THEME="?([^\"]*)"?.*/\1/')"
    ok "zsh theme:  $THEME"
  fi
fi

if command -v ss >/dev/null 2>&1; then
  SSHD_PORTS="$(ss -ltnpH 2>/dev/null | grep -i sshd \
                | awk '{print $4}' | awk -F: '{print $NF}' \
                | sort -u | tr '\n' ',' | sed 's/,$//')"
  [ -z "$SSHD_PORTS" ] || ok "sshd:       listening on ${SSHD_PORTS}"
fi

if [ -f /var/run/sshd-bootstrap-deadman.atjob ] || sudo -n test -f /var/run/sshd-bootstrap-deadman.atjob 2>/dev/null; then
  warn "SSH:        发现挂起的 deadman 任务 — 你应该跑 phase 08 confirm 或 rollback"
fi

if command -v fail2ban-client >/dev/null 2>&1; then
  if sudo -n systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "fail2ban:   service active"
  else
    warn "fail2ban:   已装但 service 未运行（sudo systemctl start fail2ban）"
  fi

  if sudo -n fail2ban-client status sshd >/dev/null 2>&1; then
    ok "fail2ban:   sshd jail active"
  else
    warn "fail2ban:   sshd jail unavailable"
  fi
fi

echo "=========================="
echo " done"
echo "=========================="
