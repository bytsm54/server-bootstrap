#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

HOME="$TMP_ROOT/default"
export HOME
unset NVM_DIR NVM_SOURCE NVM_NODEJS_ORG_MIRROR

FAKE_BIN="$HOME/fake-bin"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/git" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = clone ]; then
  shift
  source_url=''
  target_dir=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --branch) shift 2 ;;
      -*) shift ;;
      *)
        if [ -z "$source_url" ]; then source_url="$1"; else target_dir="$1"; fi
        shift
        ;;
    esac
  done
  printf '%s\n' "$source_url" >"$HOME/nvm-source"
  mkdir -p "$target_dir/.git"
  cat >"$target_dir/nvm.sh" <<'NVM'
[ "${FAKE_NVM_PAYLOAD-}" != malicious ] || touch "$HOME/unverified-nvm-executed"
nvm() {
  case "$1" in
    ls) return 0 ;;
    install)
      printf '%s\n' "${NVM_NODEJS_ORG_MIRROR-}" >"$HOME/node-mirror"
      ;;
    use|alias) return 0 ;;
  esac
}
NVM
elif [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ] && [ "${4:-}" = HEAD ]; then
  printf '%s\n' "${FAKE_NVM_COMMIT:-977563e97ddc66facf3a8e31c6cff01d236f09bd}"
else
  exec /usr/bin/git "$@"
fi
EOF

cat >"$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
echo v24.0.0
EOF

cat >"$FAKE_BIN/npm" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo 11.0.0 ;;
  config)
    case "$2" in
      get)
        if [ -s "$HOME/npm-registry" ]; then
          cat "$HOME/npm-registry"
        else
          echo https://registry.npmjs.org/
        fi
        ;;
      set) printf '%s\n' "$4" >"$HOME/npm-registry" ;;
      delete) rm -f "$HOME/npm-registry" ;;
    esac
    ;;
esac
EOF

cat >"$FAKE_BIN/npx" <<'EOF'
#!/usr/bin/env bash
echo 11.0.0
EOF

chmod +x "$FAKE_BIN/git" "$FAKE_BIN/node" "$FAKE_BIN/npm" "$FAKE_BIN/npx"
export PATH="$FAKE_BIN:/usr/bin:/bin"

bash "$ROOT_DIR/scripts/03-node.sh" --install-bun no

[ "$(cat "$HOME/nvm-source")" = "https://gitee.com/mirrors/nvm.git" ] ||
  fail "default nvm source did not use the Gitee mirror"
[ "$(cat "$HOME/node-mirror")" = "https://npmmirror.com/mirrors/node" ] ||
  fail "default Node binary download did not use npmmirror"
[ "$(cat "$HOME/npm-registry")" = "https://registry.npmmirror.com" ] ||
  fail "default npm registry did not use npmmirror"

HOME="$TMP_ROOT/override"
export HOME
unset NVM_DIR
mkdir -p "$HOME"
export NVM_SOURCE="https://mirror.example/nvm.git"
export NVM_NODEJS_ORG_MIRROR="https://mirror.example/node"

bash "$ROOT_DIR/scripts/03-node.sh" --install-bun no

[ "$(cat "$HOME/nvm-source")" = "$NVM_SOURCE" ] ||
  fail "caller-provided nvm source was replaced"
[ "$(cat "$HOME/node-mirror")" = "$NVM_NODEJS_ORG_MIRROR" ] ||
  fail "caller-provided Node mirror was replaced"

HOME="$TMP_ROOT/tampered-repository"
export HOME
unset NVM_DIR NVM_SOURCE NVM_NODEJS_ORG_MIRROR
mkdir -p "$HOME"
export FAKE_NVM_COMMIT="bad-nvm-commit"
export FAKE_NVM_PAYLOAD="malicious"
if bash "$ROOT_DIR/scripts/03-node.sh" --install-bun no >"$HOME/output" 2>&1; then
  fail "nvm repository with an unexpected commit was accepted"
fi
grep -Fq 'commit 校验失败' "$HOME/output" || fail "commit rejection reason was unclear"
[ ! -e "$HOME/unverified-nvm-executed" ] || fail "unverified nvm payload executed before commit validation"
unset FAKE_NVM_COMMIT
unset FAKE_NVM_PAYLOAD

HOME="$TMP_ROOT/official"
export HOME
unset NVM_DIR NVM_SOURCE NVM_NODEJS_ORG_MIRROR
mkdir -p "$HOME"
bash "$ROOT_DIR/scripts/03-node.sh" --npm-registry official --install-bun no
[ "$(cat "$HOME/nvm-source")" = "https://github.com/nvm-sh/nvm.git" ] ||
  fail "official profile did not use the GitHub nvm repository"
[ -z "$(cat "$HOME/node-mirror")" ] || fail "official profile set a custom Node mirror"
[ ! -e "$HOME/npm-registry" ] || fail "official profile replaced the npm registry"

echo "domestic Node mirror tests passed"
