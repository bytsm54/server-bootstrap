#!/usr/bin/env bash
# Configure the SSH jail from verified live listeners, retaining selected actions.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/ssh-state.sh"
. "$SCRIPT_DIR/lib/python-env.sh"
. "$SCRIPT_DIR/lib/fail2ban-state.sh"
MAX_RETRY=5; BAN_TIME=3600; FIND_TIME=600
while [ "$#" -gt 0 ]; do
  case "$1" in -h|--help) echo 'Usage: 09-fail2ban.sh [--max-retry N] [--ban-time seconds] [--find-time seconds]'; exit ;; esac
  [ "$#" -ge 2 ] || exit 2
  case "$1" in --max-retry) MAX_RETRY="$2" ;; --ban-time) BAN_TIME="$2" ;; --find-time) FIND_TIME="$2" ;; *) echo "未知参数: $1" >&2; exit 2 ;; esac
  shift 2
done
for value in "$MAX_RETRY" "$BAN_TIME" "$FIND_TIME"; do valid_positive_int "$value" || exit 2; done
init_privilege
if "${SUDO[@]}" test -s /var/run/sshd-bootstrap-deadman.atjob; then
  echo 'SSH 尚未确认或回滚完成，请先处理 SSH 阶段' >&2; exit 1
fi
SSH_PORTS="$(ssh_actual_ports)"
install_missing() {
  local package missing=()
  for package in "$@"; do
    [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || missing+=("$package")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}
install_missing fail2ban python3-systemd python3-venv
ensure_python_env
HELPER="$SCRIPT_DIR/lib/fail2ban_config.py"
JAIL=/etc/fail2ban/jail.d/99-server-bootstrap.local
LEGACY=/etc/fail2ban/jail.d/sshd.local
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
HAD_CONFIG=no; MIGRATE=no; CHANGED=no
"${SUDO[@]}" mkdir -p "$(dirname "$JAIL")"
for path in "$JAIL" "$LEGACY"; do
  [ ! -L "$path" ] || { echo "fail2ban 配置是软链，拒绝覆盖: $path" >&2; exit 1; }
done
if "${SUDO[@]}" test -f "$JAIL"; then
  HAD_CONFIG=yes
  "${SUDO[@]}" cp -p "$JAIL" "$TEMP/preserved"
  "${SUDO[@]}" cat "$JAIL" > "$TEMP/original"
else : > "$TEMP/original"; fi
"$BOOTSTRAP_PYTHON" "$HELPER" merge --ports "$SSH_PORTS" --retry "$MAX_RETRY" --find "$FIND_TIME" --ban "$BAN_TIME" < "$TEMP/original" > "$TEMP/new"
if "${SUDO[@]}" test -f "$LEGACY" && "${SUDO[@]}" grep -q '^# Managed by server-bootstrap 09-fail2ban' "$LEGACY"; then
  "${SUDO[@]}" cp -p "$LEGACY" "$TEMP/legacy-preserved"
  "${SUDO[@]}" cat "$LEGACY" > "$TEMP/legacy-original"
  "$BOOTSTRAP_PYTHON" "$HELPER" legacy < "$TEMP/legacy-original" > "$TEMP/legacy-new"
  cmp -s "$TEMP/legacy-original" "$TEMP/legacy-new" || MIGRATE=yes
fi
restore_config() {
  trap - ERR
  if [ "$HAD_CONFIG" = yes ]; then "${SUDO[@]}" cp -p "$TEMP/preserved" "$JAIL"
  else "${SUDO[@]}" rm -f "$JAIL"; fi
  if [ "$MIGRATE" = yes ]; then "${SUDO[@]}" cp -p "$TEMP/legacy-preserved" "$LEGACY"; fi
  "${SUDO[@]}" fail2ban-client reload --restart sshd >/dev/null 2>&1 || true
  echo 'fail2ban 配置失败，已恢复先前配置' >&2
  exit 1
}
trap restore_config ERR
if ! cmp -s "$TEMP/original" "$TEMP/new"; then
  if [ "$HAD_CONFIG" = yes ]; then "${SUDO[@]}" cp -p "$JAIL" "$JAIL.bak"; fi
  if [ "$HAD_CONFIG" = yes ]; then
    "${SUDO[@]}" cp -p "$JAIL" "$JAIL.tmp"
    "${SUDO[@]}" tee "$JAIL.tmp" < "$TEMP/new" >/dev/null
  else "${SUDO[@]}" install -m 644 "$TEMP/new" "$JAIL.tmp"; fi
  "${SUDO[@]}" mv "$JAIL.tmp" "$JAIL"
  CHANGED=yes
fi
if [ "$MIGRATE" = yes ]; then
  "${SUDO[@]}" cp -p "$LEGACY" "$LEGACY.server-bootstrap.bak"
  "${SUDO[@]}" cp -p "$LEGACY" "$LEGACY.tmp"
  "${SUDO[@]}" tee "$LEGACY.tmp" < "$TEMP/legacy-new" >/dev/null
  "${SUDO[@]}" mv "$LEGACY.tmp" "$LEGACY"
  CHANGED=yes
fi
"${SUDO[@]}" fail2ban-client -t
f2b_plan > "$TEMP/plan" || restore_config
"$BOOTSTRAP_PYTHON" "$HELPER" expected --retry "$MAX_RETRY" --find "$FIND_TIME" --ban "$BAN_TIME" < "$TEMP/plan" || restore_config
# Required firewall tools follow the configured action, not a forced iptables rule.
PACKAGES=()
PACKAGE_TEXT="$("$BOOTSTRAP_PYTHON" "$HELPER" packages < "$TEMP/plan")" || restore_config
while IFS= read -r package; do [ -z "$package" ] || PACKAGES+=("$package"); done <<< "$PACKAGE_TEXT"
install_missing ${PACKAGES[@]+"${PACKAGES[@]}"}
"${SUDO[@]}" systemctl is-enabled --quiet fail2ban || "${SUDO[@]}" systemctl enable fail2ban
"${SUDO[@]}" systemctl is-active --quiet fail2ban || "${SUDO[@]}" systemctl start fail2ban
ready=no
for attempt in 1 2 3 4 5; do
  if "${SUDO[@]}" fail2ban-client ping >/dev/null 2>&1; then ready=yes; break; fi
  sleep 1
done
[ "$ready" = yes ]
if [ "$CHANGED" = yes ] || ! f2b_check "$SSH_PORTS" < "$TEMP/plan" >/dev/null 2>&1; then
  # fail2ban 1.1 can drop a newly introduced action on plain reload.
  "${SUDO[@]}" fail2ban-client reload --restart sshd
else echo 'fail2ban 配置和运行状态一致，保留现有 jail，不重启'; fi
"${SUDO[@]}" fail2ban-client status sshd
f2b_check "$SSH_PORTS" < "$TEMP/plan" || restore_config
"${SUDO[@]}" systemctl is-active --quiet fail2ban
"${SUDO[@]}" systemctl is-enabled --quiet fail2ban
trap - ERR
printf 'fail2ban 已启用，sshd jail 实际端口: %s\n' "$SSH_PORTS"
