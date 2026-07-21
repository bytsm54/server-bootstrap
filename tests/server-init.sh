#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/server-init.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  [ "$STATUS" -eq "$expected" ] || fail "expected status $expected, got $STATUS; output: $(cat "$OUTPUT")"
}

assert_log_equals() {
  local expected="$1"
  local actual
  actual="$(cat "$CALL_LOG")"
  [ "$actual" = "$expected" ] || {
    printf 'FAIL: call log mismatch\n--- expected ---\n%s\n--- actual ---\n%s\n' "$expected" "$actual" >&2
    exit 1
  }
}

assert_log_contains() {
  grep -Fqx "$1" "$CALL_LOG" || fail "call log missing: $1"
}

assert_log_excludes() {
  if grep -Eq '(^|/)(04|04a|04b|06|07|07a)(-|\.)' "$CALL_LOG"; then
    fail "excluded AI or project phase was called: $(cat "$CALL_LOG")"
  fi
}

write_input() {
  : >"$INPUT"
  local line
  for line in "$@"; do
    printf '%s\n' "$line" >>"$INPUT"
  done
}

run_server_init() {
  : >"$CALL_LOG"
  : >"$OUTPUT"
  set +e
  env \
    REPO_DIR="$FAKE_REPO" \
    CALL_LOG="$CALL_LOG" \
    FAIL_PHASE="${FAIL_PHASE:-}" \
    FAIL_SSH_MODE="${FAIL_SSH_MODE:-}" \
    FAKE_NOW_EPOCH="${FAKE_NOW_EPOCH:-1000}" \
    FAKE_DEADLINE_EPOCH="${FAKE_DEADLINE_EPOCH:-1300}" \
    WHOAMI_RESULT="${WHOAMI_RESULT-tester}" \
    SERVER_INIT_INTERACTIVE="${INTERACTIVE:-yes}" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    bash "$SCRIPT" "$@" <"$INPUT" >"$OUTPUT" 2>&1
  STATUS=$?
  set -e
}

FAKE_REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/bin"
CALL_LOG="$TMP_DIR/calls.log"
INPUT="$TMP_DIR/input"
OUTPUT="$TMP_DIR/output"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_BIN"

cat >"$FAKE_BIN/whoami" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$WHOAMI_RESULT"
EOF
cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then
  echo "$FAKE_NOW_EPOCH"
else
  /bin/date "$@"
fi
EOF
chmod +x "$FAKE_BIN/whoami" "$FAKE_BIN/date"

for phase in \
  01-preflight.sh \
  02-base-deps.sh \
  02a-system.sh \
  02b-zsh.sh \
  03-node.sh \
  04-claude.sh \
  04a-codex.sh \
  04b-rtk.sh \
  05-git-identity.sh \
  06-project.sh \
  07-plugins.sh \
  07a-codex-skills.sh \
  08-ssh-harden.sh \
  09-fail2ban.sh \
  verify-server.sh; do
  cat >"$FAKE_REPO/scripts/$phase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
{
  printf '%s' "$name"
  if [ "$#" -gt 0 ]; then
    printf ' %s' "$@"
  fi
  printf '\n'
} >>"$CALL_LOG"
[ "${FAIL_PHASE:-}" != "$name" ] || exit 17
if [ "$name" = 08-ssh-harden.sh ]; then
  [ "${FAIL_SSH_MODE:-}" != "${1:-}" ] || exit 18
  [ "${1:-}" != deadline ] || echo "$FAKE_DEADLINE_EPOCH"
fi
EOF
  chmod +x "$FAKE_REPO/scripts/$phase"
done

# Help succeeds without validating phases or collecting input.
write_input
run_server_init --help
assert_status 0
grep -Fq -- '--install-bun' "$OUTPUT" || fail "help does not list --install-bun"
[ ! -s "$CALL_LOG" ] || fail "--help invoked phases"

# Invalid arguments fail before any phase is invoked.
write_input
run_server_init --install-bun maybe
assert_status 2
grep -Fq -- '--install-bun' "$OUTPUT" || fail "invalid Bun error does not identify --install-bun"
[ ! -s "$CALL_LOG" ] || fail "invalid yes/no invoked phases"

run_server_init --npm-registry mirror
assert_status 2
grep -Fq -- '--npm-registry' "$OUTPUT" || fail "invalid registry error does not identify --npm-registry"
[ ! -s "$CALL_LOG" ] || fail "invalid registry invoked phases"

run_server_init --ssh-port 22
assert_status 2
grep -Fq -- '--ssh-port' "$OUTPUT" || fail "invalid port error does not identify --ssh-port"
[ ! -s "$CALL_LOG" ] || fail "invalid SSH port invoked phases"

run_server_init --ssh-rollback-minutes 0
assert_status 2
grep -Fq -- '--ssh-rollback-minutes' "$OUTPUT" || fail "invalid rollback error does not identify --ssh-rollback-minutes"
[ ! -s "$CALL_LOG" ] || fail "invalid rollback window invoked phases"

run_server_init --git-name 'Test User' --git-email invalid
assert_status 2
grep -Fq -- '--git-email' "$OUTPUT" || fail "invalid email error does not identify --git-email"
[ ! -s "$CALL_LOG" ] || fail "invalid Git email invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --node-version '' --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--node-version' "$OUTPUT" || fail "empty Node version error does not identify --node-version"
[ ! -s "$CALL_LOG" ] || fail "empty Node version invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --node-version banana --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--node-version' "$OUTPUT" || fail "invalid Node version error does not identify --node-version"
[ ! -s "$CALL_LOG" ] || fail "invalid Node version invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh yes --zsh-theme '' \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--zsh-theme' "$OUTPUT" || fail "empty zsh theme error does not identify --zsh-theme"
[ ! -s "$CALL_LOG" ] || fail "empty zsh theme invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --zsh-theme '' \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--zsh-theme' "$OUTPUT" || fail "empty disabled zsh theme error does not identify --zsh-theme"
[ ! -s "$CALL_LOG" ] || fail "empty disabled zsh theme invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone '' \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--timezone' "$OUTPUT" || fail "empty timezone error does not identify --timezone"
[ ! -s "$CALL_LOG" ] || fail "empty timezone invoked phases"

write_input 'yes' '稍后'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users '' \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban no
assert_status 2
grep -Fq -- '--ssh-allow-users' "$OUTPUT" || fail "empty SSH allow-users error does not identify --ssh-allow-users"
[ ! -s "$CALL_LOG" ] || fail "empty SSH allow-users invoked phases"

write_input 'yes' '稍后'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users 'tester,' \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban no
assert_status 2
grep -Fq -- '--ssh-allow-users' "$OUTPUT" || fail "malformed SSH allow-users error does not identify --ssh-allow-users"
[ ! -s "$CALL_LOG" ] || fail "malformed SSH allow-users invoked phases"

write_input 'yes' '稍后'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users 'tester root' \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban no
assert_status 2
grep -Fq -- '--ssh-allow-users' "$OUTPUT" || fail "whitespace SSH allow-users error does not identify --ssh-allow-users"
[ ! -s "$CALL_LOG" ] || fail "whitespace SSH allow-users invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --ssh-allow-users 'tester,' --enable-fail2ban no
assert_status 2
grep -Fq -- '--ssh-allow-users' "$OUTPUT" || fail "malformed disabled SSH allow-users error does not identify --ssh-allow-users"
[ ! -s "$CALL_LOG" ] || fail "malformed disabled SSH allow-users invoked phases"

write_input 'yes'
run_server_init \
  --hostname .host --timezone UTC \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--hostname' "$OUTPUT" || fail "invalid hostname error does not identify --hostname"
[ ! -s "$CALL_LOG" ] || fail "invalid hostname invoked phases"

write_input 'yes'
run_server_init \
  --hostname edge-host --timezone ../../../etc/passwd \
  --install-zsh no --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban no
assert_status 2
grep -Fq -- '--timezone' "$OUTPUT" || fail "invalid timezone error does not identify --timezone"
[ ! -s "$CALL_LOG" ] || fail "invalid timezone invoked phases"

# A noninteractive run must have Git identity and still cannot bypass confirmation.
INTERACTIVE=no
write_input
run_server_init
assert_status 2
grep -Fq 'Git' "$OUTPUT" || fail "missing Git identity error is unclear"
[ ! -s "$CALL_LOG" ] || fail "missing Git identity invoked phases"

run_server_init --git-name 'Test User' --git-email test@example.com
assert_status 2
grep -Fq '确认' "$OUTPUT" || fail "noninteractive confirmation error is unclear"
[ ! -s "$CALL_LOG" ] || fail "noninteractive confirmation failure invoked phases"
INTERACTIVE=yes

# Default interactive collection, overall approval, and successful SSH confirmation.
write_input \
  '' '' '' '' '' '' '' \
  'Test User' 'test@example.com' \
  '' '' '' '' '' '' '' \
  'yes' '已准备' '成功'
run_server_init
assert_status 0
assert_log_equals "$(cat <<'EOF'
01-preflight.sh
02-base-deps.sh
02a-system.sh --timezone Asia/Shanghai
02b-zsh.sh --theme powerlevel10k/powerlevel10k
03-node.sh --node-version lts --npm-registry official --install-bun no
05-git-identity.sh --name Test User --email test@example.com
08-ssh-harden.sh apply --port 22022 --allow-users tester --permit-root no --password-auth no --rollback-after-minutes 5
08-ssh-harden.sh deadline
08-ssh-harden.sh confirm
09-fail2ban.sh --ssh-port 22022
verify-server.sh
EOF
)"
assert_log_excludes

# Leading-zero rollback values remain valid decimal integers during SSH confirmation.
write_input 'yes' '已准备' '成功'
run_server_init \
  --hostname edge-host --timezone UTC \
  --install-zsh yes --zsh-theme robbyrussell \
  --node-version 22 --npm-registry china --install-bun yes \
  --git-name 'CLI User' --git-email cli@example.com \
  --harden-ssh yes --ssh-port 2222 --ssh-allow-users 'alpha@*.example.com,bob?' \
  --ssh-permit-root yes --ssh-password-auth yes --ssh-rollback-minutes 08 \
  --enable-fail2ban yes
assert_status 0
assert_log_contains '02a-system.sh --hostname edge-host --timezone UTC'
assert_log_contains '02b-zsh.sh --theme robbyrussell'
assert_log_contains '08-ssh-harden.sh apply --port 2222 --allow-users alpha@*.example.com,bob? --permit-root yes --password-auth yes --rollback-after-minutes 08'
assert_log_contains '08-ssh-harden.sh confirm'
assert_log_contains '09-fail2ban.sh --ssh-port 2222'
assert_log_excludes

# Supplying every option avoids collection prompts; Bun is routed as enabled.
write_input 'yes'
run_server_init \
  --hostname '' \
  --timezone UTC \
  --install-zsh no \
  --node-version v22.1.0 \
  --npm-registry china \
  --install-bun yes \
  --git-name 'CLI User' \
  --git-email cli@example.com \
  --harden-ssh no \
  --enable-fail2ban yes
assert_status 0
assert_log_contains '03-node.sh --node-version v22.1.0 --npm-registry china --install-bun yes'
assert_log_contains '09-fail2ban.sh --ssh-port 22'
! grep -Fq '02b-zsh.sh' "$CALL_LOG" || fail "disabled zsh phase was called"
! grep -Fq '08-ssh-harden.sh' "$CALL_LOG" || fail "disabled SSH phase was called"
assert_log_excludes

# Declining the separate SSH safety gate skips hardening and keeps fail2ban on 22.
write_input 'yes' '稍后'
run_server_init \
  --hostname '' --timezone Asia/Shanghai \
  --install-zsh yes --zsh-theme powerlevel10k/powerlevel10k \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users tester \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban yes
assert_status 0
! grep -Fq '08-ssh-harden.sh' "$CALL_LOG" || fail "SSH safety-gate skip invoked SSH phase"
assert_log_contains '09-fail2ban.sh --ssh-port 22'
assert_log_excludes

# A failed second-terminal check rolls SSH back and configures fail2ban for 22.
write_input 'yes' '已准备' '失败'
run_server_init \
  --hostname '' --timezone Asia/Shanghai \
  --install-zsh yes --zsh-theme powerlevel10k/powerlevel10k \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users tester \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban yes
assert_status 0
assert_log_contains '08-ssh-harden.sh rollback'
assert_log_contains '09-fail2ban.sh --ssh-port 22'
! grep -Fqx '08-ssh-harden.sh confirm' "$CALL_LOG" || fail "failed SSH check was confirmed"
assert_log_excludes

# EOF at the second-terminal prompt follows the timeout/unknown rollback route.
FAKE_NOW_EPOCH=1000
FAKE_DEADLINE_EPOCH=1060
write_input 'yes' '已准备'
run_server_init \
  --hostname '' --timezone Asia/Shanghai \
  --install-zsh no \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users tester \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 1 \
  --enable-fail2ban yes
assert_status 0
assert_log_contains '08-ssh-harden.sh rollback'
assert_log_contains '09-fail2ban.sh --ssh-port 22'
grep -Fq '本地确认等待: 30 秒（比 deadman 提前 30 秒）' "$OUTPUT" ||
  fail "manual rollback deadline is not observably earlier than the one-minute deadman"
assert_log_excludes
unset FAKE_NOW_EPOCH FAKE_DEADLINE_EPOCH

# An SSH apply failure stops before confirm, rollback, fail2ban, and verification.
FAIL_PHASE=08-ssh-harden.sh
write_input 'yes' '已准备'
run_server_init \
  --hostname '' --timezone Asia/Shanghai --install-zsh no \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users tester \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban yes
[ "$STATUS" -ne 0 ] || fail "SSH apply failure returned success"
assert_log_contains '08-ssh-harden.sh apply --port 22022 --allow-users tester --permit-root no --password-auth no --rollback-after-minutes 5'
[ "$(grep -c '^08-ssh-harden.sh' "$CALL_LOG")" -eq 1 ] || fail "SSH apply failure invoked another SSH mode"
! grep -Fq '09-fail2ban.sh' "$CALL_LOG" || fail "SSH apply failure invoked fail2ban"
! grep -Fq 'verify-server.sh' "$CALL_LOG" || fail "SSH apply failure invoked verifier"
assert_log_excludes
unset FAIL_PHASE

# A confirm failure (including auto-before-confirm missing state) stops before fail2ban.
FAIL_SSH_MODE=confirm
write_input 'yes' '已准备' '成功'
run_server_init \
  --hostname '' --timezone Asia/Shanghai --install-zsh no \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 --ssh-allow-users tester \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban yes
[ "$STATUS" -ne 0 ] || fail "SSH confirm failure returned success"
assert_log_contains '08-ssh-harden.sh deadline'
assert_log_contains '08-ssh-harden.sh confirm'
! grep -Fq '09-fail2ban.sh' "$CALL_LOG" || fail "SSH confirm failure invoked fail2ban"
! grep -Fq 'verify-server.sh' "$CALL_LOG" || fail "SSH confirm failure invoked verifier"
assert_log_excludes
unset FAIL_SSH_MODE

# Any ordinary phase failure stops all later phases.
FAIL_PHASE=03-node.sh
write_input 'yes'
run_server_init \
  --hostname '' --timezone Asia/Shanghai --install-zsh no \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh no --enable-fail2ban yes
[ "$STATUS" -ne 0 ] || fail "phase failure returned success"
assert_log_equals "$(cat <<'EOF'
01-preflight.sh
02-base-deps.sh
02a-system.sh --timezone Asia/Shanghai
03-node.sh --node-version lts --npm-registry official --install-bun no
EOF
)"
assert_log_excludes
unset FAIL_PHASE

# Empty current-user discovery is fatal before changes when SSH defaults are used.
WHOAMI_RESULT=''
write_input 'yes'
run_server_init \
  --hostname '' --timezone Asia/Shanghai --install-zsh no \
  --node-version lts --npm-registry official --install-bun no \
  --git-name 'Test User' --git-email test@example.com \
  --harden-ssh yes --ssh-port 22022 \
  --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
  --enable-fail2ban yes
assert_status 2
[ ! -s "$CALL_LOG" ] || fail "empty whoami result invoked phases"

echo "server init orchestration tests passed"
