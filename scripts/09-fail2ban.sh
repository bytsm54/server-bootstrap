#!/usr/bin/env bash
# Configure the SSH jail from verified live listeners, never a caller's guess.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/ssh-state.sh"
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
MISSING=()
for package in fail2ban python3-systemd iptables; do
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || MISSING+=("$package")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${MISSING[@]}"
fi
JAIL=/etc/fail2ban/jail.d/99-server-bootstrap.local
TEMP="$(mktemp)"
trap 'rm -f "$TEMP"' EXIT
cat > "$TEMP" <<CONF
# Managed by server-bootstrap
[sshd]
enabled = true
backend = systemd
port = $SSH_PORTS
maxretry = $MAX_RETRY
findtime = $FIND_TIME
bantime = $BAN_TIME
action = iptables-multiport[name=sshd, port="%(port)s", protocol=tcp]
CONF
HAD_CONFIG=no
"${SUDO[@]}" mkdir -p "$(dirname "$JAIL")"
if "${SUDO[@]}" test -e "$JAIL"; then
  HAD_CONFIG=yes
  "${SUDO[@]}" cp -p "$JAIL" "$JAIL.bak"
fi
restore_config() {
  trap - ERR
  if [ "$HAD_CONFIG" = yes ]; then "${SUDO[@]}" mv "$JAIL.bak" "$JAIL"
  else "${SUDO[@]}" rm -f "$JAIL"; fi
  "${SUDO[@]}" fail2ban-client reload --restart sshd >/dev/null 2>&1 || true
  echo 'fail2ban 配置失败，已恢复先前配置' >&2
  exit 1
}
trap restore_config ERR
"${SUDO[@]}" install -m 644 "$TEMP" "$JAIL.tmp"
"${SUDO[@]}" mv "$JAIL.tmp" "$JAIL"
"${SUDO[@]}" fail2ban-client -t
"${SUDO[@]}" systemctl enable --now fail2ban
ready=no
for attempt in 1 2 3 4 5; do
  if "${SUDO[@]}" fail2ban-client ping >/dev/null 2>&1; then ready=yes; break; fi
  sleep 1
done
[ "$ready" = yes ]
# Recreate this jail when switching actions; fail2ban 1.1 can discard a newly
# added action during a plain reload. Other jails and persisted bans stay intact.
"${SUDO[@]}" fail2ban-client reload --restart sshd
"${SUDO[@]}" fail2ban-client status sshd
ACTUAL="$("${SUDO[@]}" fail2ban-client get sshd action iptables-multiport port | tr -d '[:space:]')" || restore_config
[ "$ACTUAL" = "$SSH_PORTS" ]
"${SUDO[@]}" systemctl is-active --quiet fail2ban
"${SUDO[@]}" systemctl is-enabled --quiet fail2ban
trap - ERR
printf 'fail2ban 已启用，sshd jail 实际端口: %s\n' "$SSH_PORTS"
