#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME"
unset NVM_DIR

FAKE_BIN="$HOME/fake-bin"
mkdir -p "$FAKE_BIN" "$HOME/.nvm"

cat >"$HOME/.nvm/nvm.sh" <<'EOF'
nvm() {
  case "$1" in
    ls) printf 'lts/* -> v24.0.0\n' ;;
    use|alias) return 0 ;;
    *) return 0 ;;
  esac
}
EOF

cat >"$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
echo v24.0.0
EOF

cat >"$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo 11.0.0 ;;
  prefix) echo "$HOME/.nvm/versions/node/v24.0.0" ;;
  config)
    case "$2" in
      get) echo https://registry.npmjs.org/ ;;
      set|delete) ;;
    esac
    ;;
esac
EOF

cat >"$FAKE_BIN/npx" <<'EOF'
#!/usr/bin/env bash
echo 11.0.0
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *https://bun.sh/install*)
    cat <<'INSTALLER'
mkdir -p "$HOME/.bun/bin"
cat >"$HOME/.bun/bin/bun" <<'BUN'
#!/usr/bin/env bash
echo 1.2.3
BUN
chmod +x "$HOME/.bun/bin/bun"
touch "$HOME/bun-installed"
INSTALLER
    ;;
  *) exit 1 ;;
esac
EOF

chmod +x "$FAKE_BIN/node" "$FAKE_BIN/npm" "$FAKE_BIN/npx" "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:/usr/bin:/bin"

bash "$ROOT_DIR/scripts/03-node.sh" --node-version lts --npm-registry official --install-bun no
[ ! -e "$HOME/bun-installed" ] || fail "--install-bun no should skip Bun installation"
! grep -q 'server-bootstrap:bun-path' "$HOME/.bashrc" || fail "--install-bun no should skip the Bun PATH block"

bash "$ROOT_DIR/scripts/03-node.sh" --node-version lts --npm-registry official --install-bun yes
[ -x "$HOME/.bun/bin/bun" ] || fail "--install-bun yes should install Bun"
[ -e "$HOME/bun-installed" ] || fail "the Bun installer should run"
grep -q 'server-bootstrap:bun-path' "$HOME/.bashrc" || fail "--install-bun yes should add the Bun PATH block"

echo "node Bun option tests passed"
