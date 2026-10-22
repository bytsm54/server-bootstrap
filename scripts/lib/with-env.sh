#!/usr/bin/env bash
# Load user runtimes in non-interactive shells without modifying files.
set -eo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/toolchain.sh"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  . "$NVM_DIR/nvm.sh"
  NODE_CURRENT="$(nvm which current 2>/dev/null || true)"
  [ ! -x "$NODE_CURRENT" ] || path_prepend_once "$(dirname "$NODE_CURRENT")"
fi
export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
[ ! -d "$BUN_INSTALL/bin" ] || path_append_once "$BUN_INSTALL/bin"
path_append_once "$HOME/.local/bin"
[ "${1:-}" != -- ] || shift
[ "$#" -gt 0 ] || { echo 'Usage: with-env.sh -- command [args]' >&2; exit 2; }
exec "$@"
