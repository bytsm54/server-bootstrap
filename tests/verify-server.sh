#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/verify-server.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

HOME_DIR="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
OUTPUT="$TMP_DIR/output"
CALL_LOG="$TMP_DIR/calls.log"
mkdir -p "$HOME_DIR/.nvm" "$HOME_DIR/.local/bin" "$FAKE_BIN"

cat >"$HOME_DIR/.nvm/nvm.sh" <<'EOF'
printf 'nvm.sh sourced\n' >>"$CALL_LOG"
EOF

cat >"$FAKE_BIN/command-dispatch" <<'EOF'
#!/bin/bash
set -euo pipefail

command_name="${0##*/}"
printf '%s' "$command_name" >>"$CALL_LOG"
if [ "$#" -gt 0 ]; then
  printf ' %s' "$@" >>"$CALL_LOG"
fi
printf '\n' >>"$CALL_LOG"

case "$command_name" in
  hostnamectl)
    printf 'test-server\n'
    ;;
  timedatectl)
    printf 'UTC\n'
    ;;
  node)
    printf 'v22.14.0\n'
    ;;
  npm)
    case "${1:-}" in
      --version) printf '10.9.2\n' ;;
      prefix) printf '%s/.nvm/versions/node/v22.14.0\n' "$HOME" ;;
      config) printf 'https://registry.npmjs.org/\n' ;;
    esac
    ;;
  npx)
    ;;
  git)
    case "${3:-}" in
      user.name) printf 'Test User\n' ;;
      user.email) printf 'test@example.com\n' ;;
      init.defaultBranch) printf 'main\n' ;;
    esac
    ;;
  zsh)
    printf 'zsh 5.9 (x86_64-test-linux-gnu)\n'
    ;;
  getent)
    printf 'tester:x:1000:1000:Test User:%s:%s/zsh\n' "$HOME" "$(dirname "$0")"
    ;;
  ss)
    if [[ " $* " == *" -ltnpH "* ]]; then
      printf 'LISTEN 0 128 0.0.0.0:22022 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'
    else
      printf 'LISTEN 0 128 0.0.0.0:22022 0.0.0.0:*\n'
    fi
    ;;
  sudo)
    case "${1:-}" in
      test) exit 1 ;;
      *) exec "$@" ;;
    esac
    ;;
  systemctl)
    [ "$*" = 'is-active --quiet fail2ban' ]
    ;;
  fail2ban-client)
    [ "$*" = 'status sshd' ] || exit 1
    printf 'Status for the jail: sshd\n'
    ;;
esac
EOF
chmod +x "$FAKE_BIN/command-dispatch"

for command_name in \
  node npm npx git hostnamectl timedatectl zsh getent ss sudo systemctl fail2ban-client; do
  ln -s command-dispatch "$FAKE_BIN/$command_name"
done

set +e
HOME="$HOME_DIR" \
NVM_DIR="$HOME_DIR/.nvm" \
CALL_LOG="$CALL_LOG" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
bash "$SCRIPT" >"$OUTPUT" 2>&1
STATUS=$?
set -e

[ "$STATUS" -eq 0 ] || fail "verifier exited $STATUS; output: $(cat "$OUTPUT")"

for expected in 'Node:' 'npm:' 'git:' 'zsh:' 'sshd:' 'fail2ban:'; do
  grep -Fq "$expected" "$OUTPUT" || fail "verifier output missing: $expected"
done

grep -Fq 'nvm.sh sourced' "$CALL_LOG" || fail "verifier did not source nvm.sh"
grep -Fq 'fail2ban-client status sshd' "$CALL_LOG" || fail "verifier did not inspect the fail2ban sshd jail"

for excluded in "Claude Code" "Codex" "RTK" "Plugins" "Skills" "memories"; do
  if grep -Fq "$excluded" "$OUTPUT"; then
    echo "FAIL: verifier contains excluded AI check: $excluded" >&2
    exit 1
  fi
done

echo "server-only verifier tests passed"
