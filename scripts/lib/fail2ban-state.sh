#!/usr/bin/env bash
# Caller initializes SUDO and the helper venv.
f2b_plan() {
  "${SUDO[@]}" fail2ban-client -d | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/fail2ban_config.py" plan
}
f2b_check() {
  local options=()
  [ "$(id -u)" = 0 ] || options+=(--sudo)
  "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/fail2ban_config.py" check --ports "$1" ${options[@]+"${options[@]}"}
}
