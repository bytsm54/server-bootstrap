#!/usr/bin/env bash
# Tools are prepared only for an explicitly selected project.
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/python-env.sh"
require_tool() { command -v "$1" >/dev/null || { echo "需要 $1；请先启用相应运行环境" >&2; return 1; }; }
prepare_build_tools() {
  local package missing=()
  for package in build-essential "$@"; do
    [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || missing+=("$package")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    init_privilege
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}
prepare_uv() {
  if command -v uv >/dev/null; then return; fi
  local tool_env="$HOME/.local/share/server-bootstrap/uv-venv"
  [ -x "$tool_env/bin/python" ] || python3 -m venv "$tool_env"
  "$tool_env/bin/python" -c 'import sys; assert sys.prefix != sys.base_prefix'
  [ -x "$tool_env/bin/uv" ] || "$tool_env/bin/python" -m pip install uv
  export PATH="$tool_env/bin:$PATH"
}
prepare_node_manager() {
  local manager="$1" requested="$2" prefix="$HOME/.local/share/server-bootstrap/corepack"
  # Reuse existing tools when the project does not pin a different version.
  if command -v "$manager" >/dev/null && { [ -z "$requested" ] || { [[ "$requested" != *+* ]] && [ "$("$manager" --version)" = "$requested" ]; }; }; then
    MANAGER=("$manager"); return
  fi
  require_tool npm
  if ! command -v corepack >/dev/null; then
    [ -x "$prefix/bin/corepack" ] || npm install --global --prefix "$prefix" corepack
    export PATH="$prefix/bin:$PATH"
  fi
  # Do not overwrite global shims or edit package.json to select a version.
  export COREPACK_ENABLE_AUTO_PIN=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0
  if [ -n "$requested" ]; then MANAGER=(corepack "$manager@$requested")
  elif [ "$manager" = yarn ] && grep -q '^# yarn lockfile v1' yarn.lock; then MANAGER=(corepack yarn@1)
  else MANAGER=(corepack "$manager"); fi
  "${MANAGER[@]}" --version
}
