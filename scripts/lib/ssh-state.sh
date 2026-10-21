#!/usr/bin/env bash
# Read-only SSH inspection. Call init_privilege first (SUDO is an array).
ssh_effective_config() {
  local daemon
  daemon="$(command -v sshd || true)"
  [ -n "$daemon" ] || daemon=/usr/sbin/sshd
  "${SUDO[@]}" "$daemon" -T "$@"
}
ssh_socket_unit() {
  local unit
  for unit in ssh.socket sshd.socket; do
    if "${SUDO[@]}" systemctl is-active --quiet "$unit" 2>/dev/null; then printf '%s\n' "$unit"; return; fi
  done
  return 1
}
ssh_socket_addresses() {
  local listen
  listen="$("${SUDO[@]}" systemctl show "$1" --property=Listen --value)" || return 1
  printf '%s\n' "$listen" | sed 's/) /)\n/g' | sed -nE 's/^([^ ]+) \(Stream\)$/\1/p'
}
ssh_main_pid() {
  local unit pid
  for unit in ssh.service sshd.service; do
    pid="$("${SUDO[@]}" systemctl show "$unit" --property=MainPID --value 2>/dev/null)" || continue
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$pid"; return; fi
  done
  return 1
}
ssh_actual_listener_rows() {
  local listeners pid unit addresses
  listeners="$("${SUDO[@]}" ss -ltnpH)" || return 1
  pid="$(ssh_main_pid || true)"
  unit="$(ssh_socket_unit || true)"
  addresses=''
  if [ -n "$unit" ]; then addresses="$(ssh_socket_addresses "$unit")" || return 1; fi
  # Only the service's main daemon or PID 1 on this socket's exact endpoint.
  # Child sshd/sshd-session processes may own reverse tunnels, not login ports.
  printf '%s\n' "$listeners" | awk -v pid="$pid" -v addresses="$addresses" '
    function normalize(address) {sub(/^\[::\]:/, "*:", address); return address}
    BEGIN {n=split(addresses,a,"\n"); for(i=1;i<=n;i++) sockets[normalize(a[i])]=1}
    pid!="" && index($0,"(\"sshd\",pid=" pid ",") {print; next}
    index($0,"(\"systemd\",pid=1,") && sockets[normalize($4)] {print}
  '
}
ssh_actual_ports() {
  local rows result
  rows="$(ssh_actual_listener_rows)" || return 1
  result="$(printf '%s\n' "$rows" | awk 'NF {n=split($4,a,":"); print a[n]}' | sort -nu | paste -sd, -)"
  [ -n "$result" ] || { echo '无法确认 SSH 的实际监听端口及主进程归属' >&2; return 1; }
  printf '%s\n' "$result"
}
ssh_port_available() {
  local port="$1" rows allowed row
  allowed="$(ssh_actual_listener_rows)" || return 1
  [ -n "$allowed" ] || return 1
  rows="$("${SUDO[@]}" ss -ltnpH)" || return 1
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    if ! printf '%s\n' "$allowed" | grep -qxF "$row"; then
      echo "端口 $port 已被其他服务或 SSH 转发占用" >&2; return 1
    fi
  done < <(printf '%s\n' "$rows" | awk -v p="$port" '$4 ~ (":" p "$")')
}

ssh_reload_daemon() {
  local unit
  for unit in ssh.service sshd.service; do
    if "${SUDO[@]}" systemctl is-active --quiet "$unit" 2>/dev/null; then
      "${SUDO[@]}" systemctl reload "$unit"; return
    fi
  done
  # A listening socket with an inactive daemon is a valid on-demand state.
  ssh_socket_unit >/dev/null
}
