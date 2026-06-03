#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/toolchain.sh
. "$ROOT_DIR/scripts/lib/toolchain.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_exe() {
  local path="$1" text="$2"
  mkdir -p "$(dirname "$path")"
  printf '#!/usr/bin/env bash\necho %s\n' "$text" >"$path"
  chmod +x "$path"
}

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"

NVM_BIN="$HOME/.nvm/versions/node/v24.16.0/bin"
HERMES_BIN="$HOME/.hermes/node/bin"
mkdir -p "$HOME/.local/bin" "$NVM_BIN" "$HERMES_BIN"

for tool in node npm npx; do
  make_exe "$NVM_BIN/$tool" "nvm-$tool"
  make_exe "$HERMES_BIN/$tool" "hermes-$tool"
  ln -s "$HERMES_BIN/$tool" "$HOME/.local/bin/$tool"
done

PATH="$HOME/.local/bin:$NVM_BIN:/usr/bin:/bin"
ensure_managed_node_toolchain "$NVM_BIN"

for tool in node npm npx; do
  [ ! -e "$HOME/.local/bin/$tool" ] || fail "~/.local/bin/$tool should be removed when it shadows nvm"
  [ "$(command -v "$tool")" = "$NVM_BIN/$tool" ] || fail "$tool should resolve to nvm bin"
done

rm -f "$HOME/.local/bin/npm"
printf '#!/usr/bin/env bash\necho local\n' >"$HOME/.local/bin/npm"
chmod +x "$HOME/.local/bin/npm"
[ -f "$HOME/.local/bin/npm" ] || fail "test setup failed to create non-symlink npm"
if ensure_managed_node_toolchain "$NVM_BIN" 2>/dev/null; then
  fail "non-symlink ~/.local/bin/npm should fail instead of being overwritten"
fi
rm -f "$HOME/.local/bin/npm"

CODEX_PREFIX="$HOME/.nvm/versions/node/v24.16.0"
make_exe "$CODEX_PREFIX/bin/codex" "codex"
ensure_codex_shim_for_prefix "$CODEX_PREFIX"
[ -L "$HOME/.local/bin/codex" ] || fail "codex shim should be a symlink"
[ "$(readlink "$HOME/.local/bin/codex")" = "$CODEX_PREFIX/bin/codex" ] || fail "codex shim should point at npm prefix bin"

echo "toolchain path tests passed"
