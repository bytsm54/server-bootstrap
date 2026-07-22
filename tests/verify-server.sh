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

assert_contains() {
  local pattern="$1" file="$2"
  grep -Fq "$pattern" "$file" || fail "output missing: $pattern"
}

assert_excludes() {
  local pattern="$1" file="$2"
  ! grep -Fq "$pattern" "$file" || fail "output unexpectedly contains: $pattern"
}

assert_in_order() {
  local file="$1"
  shift
  local previous=0 pattern line
  for pattern in "$@"; do
    line="$(grep -nF "$pattern" "$file" | head -1 | cut -d: -f1 || true)"
    [ -n "$line" ] || fail "ordered output missing: $pattern"
    [ "$line" -gt "$previous" ] || fail "output is out of order at: $pattern"
    previous="$line"
  done
}

assert_noninteractive_sudo() {
  local file="$1"
  assert_contains 'sudo -n test -f /var/run/sshd-bootstrap-deadman.atjob' "$file"
  assert_contains 'sudo -n systemctl is-active --quiet fail2ban' "$file"
  assert_contains 'sudo -n fail2ban-client status sshd' "$file"
  if grep -Eq '^sudo (test|systemctl|fail2ban-client)' "$file"; then
    fail "verifier used interactive sudo: $(grep -E '^sudo (test|systemctl|fail2ban-client)' "$file")"
  fi
}

run_verifier() {
  local fake_bin="$1" home_dir="$2" output="$3" call_log="$4"
  local deadman="$5" fail2ban_active="$6" fail2ban_jail="$7"
  : >"$output"
  : >"$call_log"
  set +e
  HOME="$home_dir" \
  NVM_DIR="$home_dir/.nvm" \
  CALL_LOG="$call_log" \
  FAKE_DEADMAN="$deadman" \
  FAKE_FAIL2BAN_ACTIVE="$fail2ban_active" \
  FAKE_FAIL2BAN_JAIL="$fail2ban_jail" \
  PATH="$fake_bin" \
  /bin/bash "$SCRIPT" >"$output" 2>&1
  STATUS=$?
  set -e
  [ "$STATUS" -eq 0 ] || fail "verifier exited $STATUS; output: $(cat "$output")"
}

HOME_DIR="$TMP_DIR/home"
FULL_BIN="$TMP_DIR/full-bin"
MINIMAL_BIN="$TMP_DIR/minimal-bin"
mkdir -p "$HOME_DIR/.nvm" "$HOME_DIR/.local/bin" "$FULL_BIN" "$MINIMAL_BIN"

cat >"$HOME_DIR/.nvm/nvm.sh" <<'EOF'
printf 'nvm.sh sourced\n' >>"$CALL_LOG"
EOF
printf 'ZSH_THEME="agnoster"\n' >"$HOME_DIR/.zshrc"

cat >"$TMP_DIR/command-dispatch" <<'EOF'
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
  bun)
    printf '1.2.3\n'
    ;;
  git)
    [ "${FAKE_GIT_IDENTITY:-yes}" = yes ] || exit 0
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
    printf 'tester:x:1000:1000:Test User:%s:%s/zsh\n' "$HOME" "${0%/*}"
    ;;
  ss)
    printf 'LISTEN 0 128 0.0.0.0:22022 0.0.0.0:* users:(("sshd",pid=123,fd=3))\n'
    ;;
  sudo)
    if [ "${1:-}" = -n ]; then
      shift
    fi
    case "${1:-}" in
      test) [ "$FAKE_DEADMAN" = yes ] ;;
      *) exec "$@" ;;
    esac
    ;;
  systemctl)
    [ "$*" = 'is-active --quiet fail2ban' ] && [ "$FAKE_FAIL2BAN_ACTIVE" = yes ]
    ;;
  fail2ban-client)
    [ "$*" = 'status sshd' ] && [ "$FAKE_FAIL2BAN_JAIL" = active ] || exit 1
    printf 'Status for the jail: sshd\n'
    ;;
esac
EOF
chmod +x "$TMP_DIR/command-dispatch"

for fake_bin in "$FULL_BIN" "$MINIMAL_BIN"; do
  for core_command in dirname date id cut awk grep sort tr sed head; do
    ln -s "$(command -v "$core_command")" "$fake_bin/$core_command"
  done
  for required_fake in git hostnamectl timedatectl sudo; do
    ln -s "$TMP_DIR/command-dispatch" "$fake_bin/$required_fake"
  done
done

for optional_fake in node npm npx bun zsh getent ss systemctl fail2ban-client; do
  ln -s "$TMP_DIR/command-dispatch" "$FULL_BIN/$optional_fake"
done

FULL_OUTPUT="$TMP_DIR/full-output"
FULL_CALL_LOG="$TMP_DIR/full-calls.log"
FAKE_GIT_IDENTITY=yes run_verifier \
  "$FULL_BIN" "$HOME_DIR" "$FULL_OUTPUT" "$FULL_CALL_LOG" yes yes active

assert_in_order "$FULL_OUTPUT" \
  'hostname:' \
  'timezone:' \
  'Node:' \
  'npm:' \
  'Toolchain:  node' \
  'Toolchain:  npm' \
  'Toolchain:  npx' \
  'Bun:' \
  'git:' \
  'git branch:' \
  'zsh:' \
  'zsh theme:' \
  'sshd:' \
  'SSH:' \
  'fail2ban:   service active' \
  'fail2ban:   sshd jail active'

assert_contains 'nvm.sh sourced' "$FULL_CALL_LOG"
assert_noninteractive_sudo "$FULL_CALL_LOG"

for excluded in "Claude Code" "Codex" "RTK" "Plugins" "Skills" "memories"; do
  assert_excludes "$excluded" "$FULL_OUTPUT"
done

MINIMAL_OUTPUT="$TMP_DIR/minimal-output"
MINIMAL_CALL_LOG="$TMP_DIR/minimal-calls.log"
FAKE_GIT_IDENTITY=no run_verifier \
  "$MINIMAL_BIN" "$HOME_DIR" "$MINIMAL_OUTPUT" "$MINIMAL_CALL_LOG" no no inactive

assert_contains '❌ Node:' "$MINIMAL_OUTPUT"
assert_contains '❌ npm:' "$MINIMAL_OUTPUT"
assert_contains '❌ git:' "$MINIMAL_OUTPUT"
for absent_optional in 'Bun:' 'zsh:' 'zsh theme:' 'sshd:' 'fail2ban:'; do
  assert_excludes "$absent_optional" "$MINIMAL_OUTPUT"
done
assert_contains 'sudo -n test -f /var/run/sshd-bootstrap-deadman.atjob' "$MINIMAL_CALL_LOG"

INACTIVE_OUTPUT="$TMP_DIR/inactive-output"
INACTIVE_CALL_LOG="$TMP_DIR/inactive-calls.log"
FAKE_GIT_IDENTITY=yes run_verifier \
  "$FULL_BIN" "$HOME_DIR" "$INACTIVE_OUTPUT" "$INACTIVE_CALL_LOG" no no inactive

assert_contains '⚠️  fail2ban:   已装但 service 未运行' "$INACTIVE_OUTPUT"
assert_contains '⚠️  fail2ban:   sshd jail unavailable' "$INACTIVE_OUTPUT"
assert_noninteractive_sudo "$INACTIVE_CALL_LOG"

echo "server-only verifier tests passed"
