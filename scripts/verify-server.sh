#!/usr/bin/env bash
# Read-only checks. Missing required evidence is not reported as success.
set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/ssh-state.sh"
. "$SCRIPT_DIR/lib/toolchain.sh"
config_defaults
parse_config "$@" || exit 2
validate_config || exit 2
FAILED=0; UNVERIFIED=0
ok() { printf '[成功] %s\n' "$*"; }
skip() { printf '[跳过] %s\n' "$*"; }
fail() { printf '[失败] %s\n' "$*"; FAILED=$((FAILED+1)); }
unknown() { printf '[未验证] %s\n' "$*"; UNVERIFIED=$((UNVERIFIED+1)); }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else fail "$label"; fi; }
if [ -r /etc/os-release ]; then . /etc/os-release; fi
[ "${ID:-}" = ubuntu ] && ok 'Ubuntu' || fail '需要 Ubuntu'
for tool in git curl; do check "$tool" "$tool" --version; done
VENV="${BOOTSTRAP_VENV:-$SCRIPT_DIR/../.venv}"
check '专用 Python venv' "$VENV/bin/python" -c 'import sys; assert sys.prefix != sys.base_prefix'
HOST="$(hostnamectl --static 2>/dev/null)"
ZONE="$(timedatectl show --property=Timezone --value 2>/dev/null)"
if [ -n "$HOSTNAME_VALUE" ]; then check "hostname=$HOSTNAME_VALUE" test "$HOST" = "$HOSTNAME_VALUE"; else skip "主机名保持现状 ($HOST)"; fi
if [ -n "$TIMEZONE" ]; then check "timezone=$TIMEZONE" test "$ZONE" = "$TIMEZONE"; else skip "时区保持现状 ($ZONE)"; fi
NAME="$(git config --global user.name 2>/dev/null)"; EMAIL="$(git config --global user.email 2>/dev/null)"
if [ -n "$NAME" ] && [ -n "$EMAIL" ] && { [ -z "$GIT_NAME" ] || [ "$NAME" = "$GIT_NAME" ]; } && { [ -z "$GIT_EMAIL" ] || [ "$EMAIL" = "$GIT_EMAIL" ]; }; then ok 'Git 身份'; else fail 'Git 身份'; fi
if [ "$INSTALL_NODE" = yes ]; then
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    . "$NVM_DIR/nvm.sh"
    if [ "$NODE_VERSION" = lts ]; then wanted="$(nvm version 'lts/*')"; else wanted="$(nvm version "$NODE_VERSION")"; fi
    check 'Node 版本' test "$(node --version 2>/dev/null)" = "$wanted"
    check npm npm --version
    check npx npx --version
    case "$NPM_REGISTRY" in china) registry=https://registry.npmmirror.com ;; official) registry=https://registry.npmjs.org ;; esac
    actual="$(npm config get registry 2>/dev/null)"
    check 'npm registry' test "${actual%/}" = "$registry"
  else fail 'nvm'; fi
else skip Node; fi
if [ "$INSTALL_BUN" = yes ]; then check Bun "$HOME/.bun/bin/bun" --version; else skip Bun; fi
if [ "$INSTALL_ZSH" = yes ]; then
  check zsh zsh --version
  check 'zsh 配置语法' zsh -n "$HOME/.zshrc"
  check '默认 zsh' test "$(getent passwd "$(id -un)" | cut -d: -f7)" = "$(command -v zsh)"
  # Load the actual interactive configuration without update/configuration prompts.
  check "oh-my-zsh 与主题加载 ($ZSH_THEME)" env DISABLE_AUTO_UPDATE=true \
    POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true zsh -ic '
      [[ -r "$ZSH/oh-my-zsh.sh" && "$ZSH_THEME" == "$1" ]] || exit 1
      (( $+functions[omz] )) || exit 1
      if [[ "$1" == powerlevel10k/* ]]; then
        (( $+functions[p10k] )) || exit 1
      fi
    ' zsh "$ZSH_THEME"
else skip zsh; fi
if [ -n "$PROJECT_REPO" ]; then
  PROJECT_DIR="${PROJECT_DIR:-$HOME/$(basename "$PROJECT_REPO" .git)}"
  check '项目来源' test "$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null)" = "$PROJECT_REPO"
  if [ -f "$PROJECT_DIR/.server-bootstrap-prepared" ]; then
    check '项目依赖准备记录' test "$(cat "$PROJECT_DIR/.server-bootstrap-prepared")" = "$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)"
  else unknown '项目依赖尚无成功准备记录'; fi
else skip '项目准备'; fi
PRIVILEGE=no
if init_privilege noninteractive && "${SUDO[@]}" true 2>/dev/null; then PRIVILEGE=yes; fi
PORTS=''
if [ "$HARDEN_SSH" = yes ] || [ "$ENABLE_FAIL2BAN" = yes ]; then
  if [ "$PRIVILEGE" = yes ]; then
    if PORTS="$(ssh_actual_ports)"; then ok "SSH 实际监听: $PORTS"; else fail 'SSH 监听归属'; fi
  else unknown 'sudo 不可用，无法核验 SSH/fail2ban'; fi
fi
if [ "$HARDEN_SSH" = yes ] && [ "$PRIVILEGE" = yes ]; then
  check 'SSH 语法' "${SUDO[@]}" sshd -t
  if [ -n "$SSH_PORT" ]; then check 'SSH 目标端口' test "$PORTS" = "$((10#$SSH_PORT))"; fi
  client="${SSH_CONNECTION:-}"; client="${client%% *}"; client="${client:-127.0.0.1}"
  IFS=',' read -r -a users <<< "$SSH_ALLOW_USERS"
  for user in "${users[@]}"; do
    config="$(ssh_effective_config -C "user=$user,host=$client,addr=$client")"
    for pair in "permitrootlogin:$SSH_PERMIT_ROOT" "passwordauthentication:$SSH_PASSWORD_AUTH" "kbdinteractiveauthentication:$SSH_PASSWORD_AUTH" 'pubkeyauthentication:yes'; do
      key="${pair%%:*}"
      check "SSH $user $key" test "$(printf '%s\n' "$config" | awk -v k="$key" '$1==k {print $2}')" = "${pair#*:}"
    done
    actual_users="$(printf '%s\n' "$config" | awk '$1=="allowusers" {for(i=2;i<=NF;i++) print $i}' | sort -u | paste -sd, -)"
    expected_users="$(printf '%s\n' "$SSH_ALLOW_USERS" | tr ',' '\n' | sort -u | paste -sd, -)"
    check "SSH $user AllowUsers" test "$actual_users" = "$expected_users"
  done
  if [ "$SSH_PERMIT_ROOT" = no ]; then
    root_config="$(ssh_effective_config -C "user=root,host=$client,addr=$client")"
    check 'SSH root 禁用' test "$(printf '%s\n' "$root_config" | awk '$1=="permitrootlogin" {print $2}')" = no
  fi
  if "${SUDO[@]}" test -s /var/run/sshd-bootstrap-deadman.atjob; then unknown 'SSH 等待确认或回滚';
  elif "${SUDO[@]}" test -s /var/lib/server-bootstrap/ssh-confirmed && "${SUDO[@]}" sha256sum -c /var/lib/server-bootstrap/ssh-confirmed >/dev/null 2>&1; then ok 'SSH 第二连接已确认，托管配置校验和一致';
  else unknown 'SSH 第二连接未确认，或确认后配置已变化'; fi
elif [ "$HARDEN_SSH" = no ]; then skip 'SSH 加固'; fi
if [ "$ENABLE_FAIL2BAN" = yes ] && [ "$PRIVILEGE" = yes ]; then
  check 'fail2ban 配置' "${SUDO[@]}" fail2ban-client -t
  check 'fail2ban 自启' "${SUDO[@]}" systemctl is-enabled --quiet fail2ban
  check 'fail2ban 运行' "${SUDO[@]}" systemctl is-active --quiet fail2ban
  check 'sshd jail' "${SUDO[@]}" fail2ban-client status sshd
  actual="$("${SUDO[@]}" fail2ban-client get sshd action iptables-multiport port 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$PORTS" ] && [ "$actual" = "$PORTS" ]; then ok 'fail2ban 端口与 SSH 一致'; else fail 'fail2ban 端口与 SSH 不一致'; fi
elif [ "$ENABLE_FAIL2BAN" = no ]; then skip fail2ban; fi
printf '验收结果：失败 %s 项，未验证 %s 项\n' "$FAILED" "$UNVERIFIED"
[ "$FAILED" -eq 0 ] && [ "$UNVERIFIED" -eq 0 ]
