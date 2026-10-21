#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
HOSTNAME_VALUE=''; TIMEZONE=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || exit 2
  case "$1" in --hostname) HOSTNAME_VALUE="$2" ;; --timezone) TIMEZONE="$2" ;; *) exit 2 ;; esac
  shift 2
done
valid_hostname "$HOSTNAME_VALUE" && valid_timezone "$TIMEZONE" || exit 2
if [ -z "$HOSTNAME_VALUE" ] && [ -z "$TIMEZONE" ]; then echo '主机名和时区保持现状'; exit 0; fi
init_privilege
if [ -n "$HOSTNAME_VALUE" ]; then
  current="$(hostnamectl --static)"
  if [ "$current" != "$HOSTNAME_VALUE" ]; then "${SUDO[@]}" hostnamectl set-hostname "$HOSTNAME_VALUE"; fi
  # Also repair /etc/hosts when hostname already matches; preserve existing aliases.
  temporary="$(mktemp)"
  trap 'rm -f "$temporary"' EXIT
  awk -v host="$HOSTNAME_VALUE" '
    $1=="127.0.1.1" {$2=host; found=1} {print}
    END {if (!found) print "127.0.1.1 " host}
  ' /etc/hosts > "$temporary"
  if ! cmp -s "$temporary" /etc/hosts; then
    "${SUDO[@]}" cp -p /etc/hosts /etc/hosts.server-bootstrap.bak
    "${SUDO[@]}" install -m 644 "$temporary" /etc/hosts.server-bootstrap.tmp
    "${SUDO[@]}" mv /etc/hosts.server-bootstrap.tmp /etc/hosts
  fi
fi
if [ -n "$TIMEZONE" ] && [ "$(timedatectl show --property=Timezone --value)" != "$TIMEZONE" ]; then
  "${SUDO[@]}" timedatectl set-timezone "$TIMEZONE"
fi
