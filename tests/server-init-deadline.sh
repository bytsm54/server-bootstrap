#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/server-init.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_REPO="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/bin"
CALL_LOG="$TMP_DIR/calls.log"
INPUT="$TMP_DIR/input"
OUTPUT="$TMP_DIR/output"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_BIN"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ]; then
  echo "$FAKE_NOW_EPOCH"
else
  /bin/date "$@"
fi
EOF
chmod +x "$FAKE_BIN/date"

for phase in \
  01-preflight.sh 02-base-deps.sh 02a-system.sh 02b-zsh.sh 03-node.sh \
  05-git-identity.sh 09-fail2ban.sh verify-server.sh; do
  cat >"$FAKE_REPO/scripts/$phase" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >>"$CALL_LOG"
printf ' %s' "$@" >>"$CALL_LOG"
printf '\n' >>"$CALL_LOG"
EOF
  chmod +x "$FAKE_REPO/scripts/$phase"
done

cat >"$FAKE_REPO/scripts/08-ssh-harden.sh" <<'EOF'
#!/usr/bin/env bash
printf '08-ssh-harden.sh %s\n' "$*" >>"$CALL_LOG"
if [ "${1:-}" = deadline ]; then
  [ "${FAKE_DEADLINE_MISSING:-}" != yes ] || exit 17
  echo "$FAKE_DEADLINE_EPOCH"
fi
EOF
chmod +x "$FAKE_REPO/scripts/08-ssh-harden.sh"

run_case() {
  : >"$CALL_LOG"
  : >"$OUTPUT"
  set +e
  env \
    REPO_DIR="$FAKE_REPO" \
    CALL_LOG="$CALL_LOG" \
    SERVER_INIT_INTERACTIVE=yes \
    FAKE_NOW_EPOCH="$FAKE_NOW_EPOCH" \
    FAKE_DEADLINE_EPOCH="$FAKE_DEADLINE_EPOCH" \
    FAKE_DEADLINE_MISSING="${FAKE_DEADLINE_MISSING:-}" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    bash "$SCRIPT" \
      --hostname '' --timezone UTC --install-zsh no \
      --node-version lts --npm-registry official --install-bun no \
      --git-name 'Test User' --git-email test@example.com \
      --harden-ssh yes --ssh-port 22022 --ssh-allow-users tester \
      --ssh-permit-root no --ssh-password-auth no --ssh-rollback-minutes 5 \
      --enable-fail2ban yes <"$INPUT" >"$OUTPUT" 2>&1
  STATUS=$?
  set -e
}

# Forty-five seconds consumed by apply must reduce the remaining manual wait.
FAKE_NOW_EPOCH=1000000045
FAKE_DEADLINE_EPOCH=1000000300
unset FAKE_DEADLINE_MISSING
printf 'yes\n已准备\n成功\n' >"$INPUT"
run_case
[ "$STATUS" -eq 0 ] || fail "delayed apply success path failed: $(cat "$OUTPUT")"
grep -Fqx '08-ssh-harden.sh deadline' "$CALL_LOG" || fail "server-init did not read the armed deadline"
grep -Fq '本地确认等待: 225 秒（比 deadman 提前 30 秒）' "$OUTPUT" ||
  fail "server-init restarted a relative timer instead of using remaining time"
grep -Fqx '09-fail2ban.sh --ssh-port 22022' "$CALL_LOG" ||
  fail "confirmed delayed apply did not route the new port"

# If apply returns inside the margin, rollback immediately without accepting success input.
FAKE_NOW_EPOCH=1000000050
FAKE_DEADLINE_EPOCH=1000000060
printf 'yes\n已准备\n成功\n' >"$INPUT"
run_case
[ "$STATUS" -eq 0 ] || fail "too-close deadline rollback path failed: $(cat "$OUTPUT")"
grep -Fqx '08-ssh-harden.sh rollback' "$CALL_LOG" || fail "too-close deadline did not roll back"
if grep -Fqx '08-ssh-harden.sh confirm' "$CALL_LOG"; then
  fail "too-close deadline accepted confirmation"
fi
grep -Fqx '09-fail2ban.sh --ssh-port 22' "$CALL_LOG" ||
  fail "too-close deadline did not keep fail2ban on port 22"

# A missing deadline stops without an unowned rollback or fail2ban.
FAKE_NOW_EPOCH=1000000000
FAKE_DEADLINE_EPOCH=1000000300
FAKE_DEADLINE_MISSING=yes
printf 'yes\n已准备\n' >"$INPUT"
run_case
[ "$STATUS" -ne 0 ] || fail "missing deadline did not stop server-init"
grep -Fqx '08-ssh-harden.sh deadline' "$CALL_LOG" || fail "deadline mode was not invoked"
if grep -Fqx '08-ssh-harden.sh rollback' "$CALL_LOG"; then
  fail "missing deadline triggered an unowned rollback"
fi
if grep -Fq '09-fail2ban.sh' "$CALL_LOG"; then
  fail "missing deadline reached fail2ban"
fi

echo "server init absolute deadline tests passed"
