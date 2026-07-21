#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/fake-bin"
COMMAND_LOG="$TMP_DIR/commands.log"
OUTPUT="$TMP_DIR/output.log"
STATE_FILE="$TMP_DIR/deadman.state"
SSHD_COUNT="$TMP_DIR/sshd.count"
LOCK_FILE="$TMP_DIR/phase08.lock"
mkdir -p "$FAKE_BIN"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_status() {
  local expected="$1"
  [ "$STATUS" -eq "$expected" ] ||
    fail "expected status $expected, got $STATUS; output: $(cat "$OUTPUT")"
}

assert_log_contains() {
  grep -Fq -- "$1" "$COMMAND_LOG" ||
    fail "command log missing '$1': $(cat "$COMMAND_LOG")"
}

assert_log_excludes() {
  if grep -Fq -- "$1" "$COMMAND_LOG"; then
    fail "command log unexpectedly contains '$1': $(cat "$COMMAND_LOG")"
  fi
}

line_number() {
  grep -Fn -- "$1" "$COMMAND_LOG" | head -1 | cut -d: -f1
}

assert_before() {
  local first="$1" second="$2"
  local first_line second_line
  first_line="$(line_number "$first")"
  second_line="$(line_number "$second")"
  [ -n "$first_line" ] || fail "missing ordering marker: $first"
  [ -n "$second_line" ] || fail "missing ordering marker: $second"
  [ "$first_line" -lt "$second_line" ] ||
    fail "expected '$first' before '$second': $(cat "$COMMAND_LOG")"
}

reset_case() {
  : >"$COMMAND_LOG"
  : >"$OUTPUT"
  : >"$SSHD_COUNT"
  rm -f "$STATE_FILE" "$STATE_FILE.tmp" "$LOCK_FILE"
  unset FAKE_AT_FAIL FAKE_ATRM_FAIL FAKE_ATRM_SLEEP FAKE_SSHD_FAIL_ONCE FAKE_RESTORE_FAIL
  export FAKE_JOB_ID=101
  export FAKE_LATEST_BACKUP=/var/backups/sshd-bootstrap/sshd-latest.tar.gz
}

write_new_record() {
  printf '%s\n%s\n%s\n%s\n' "$1" "$2" "${3:-2000000300}" "${4:-armed}" >"$STATE_FILE"
}

run_second_pass_case() {
  [ "${SSH_SECOND_PASS_CASE:-all}" = all ] ||
    [ "${SSH_SECOND_PASS_CASE:-}" = "$1" ]
}

run_ssh() {
  set +e
  env \
    COMMAND_LOG="$COMMAND_LOG" \
    STATE_FILE="$STATE_FILE" \
    SSHD_COUNT="$SSHD_COUNT" \
    FAKE_AT_FAIL="${FAKE_AT_FAIL:-}" \
    FAKE_ATRM_FAIL="${FAKE_ATRM_FAIL:-}" \
    FAKE_ATRM_SLEEP="${FAKE_ATRM_SLEEP:-}" \
    FAKE_SSHD_FAIL_ONCE="${FAKE_SSHD_FAIL_ONCE:-}" \
    FAKE_RESTORE_FAIL="${FAKE_RESTORE_FAIL:-}" \
    FAKE_JOB_ID="$FAKE_JOB_ID" \
    FAKE_LATEST_BACKUP="$FAKE_LATEST_BACKUP" \
    SSH_HARDEN_LOCK_FILE="$LOCK_FILE" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    bash "$ROOT_DIR/scripts/08-ssh-harden.sh" "$@" >"$OUTPUT" 2>&1
  STATUS=$?
  set -e
}

start_ssh_process() {
  local process_output="$1"
  shift
  env \
    COMMAND_LOG="$COMMAND_LOG" \
    STATE_FILE="$STATE_FILE" \
    SSHD_COUNT="$SSHD_COUNT" \
    FAKE_AT_FAIL="${FAKE_AT_FAIL:-}" \
    FAKE_ATRM_FAIL="${FAKE_ATRM_FAIL:-}" \
    FAKE_ATRM_SLEEP="${FAKE_ATRM_SLEEP:-}" \
    FAKE_SSHD_FAIL_ONCE="${FAKE_SSHD_FAIL_ONCE:-}" \
    FAKE_RESTORE_FAIL="${FAKE_RESTORE_FAIL:-}" \
    FAKE_JOB_ID="$FAKE_JOB_ID" \
    FAKE_LATEST_BACKUP="$FAKE_LATEST_BACKUP" \
    SSH_HARDEN_LOCK_FILE="$LOCK_FILE" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    bash "$ROOT_DIR/scripts/08-ssh-harden.sh" "$@" >"$process_output" 2>&1 &
  STARTED_PID=$!
}

run_apply() {
  run_ssh apply \
    --port 22022 \
    --allow-users tester \
    --permit-root no \
    --password-auth yes \
    --rollback-after-minutes 5
}

cat >"$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  echo 1000
  exit 0
fi
exit 1
EOF

cat >"$FAKE_BIN/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%s) echo 2000000000 ;;
  *) echo 20260722-000000 ;;
esac
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >>"$COMMAND_LOG"
command_name="${1:-}"
shift || true

case "$command_name" in
  /usr/bin/env)
    exec /usr/bin/env "$@"
    ;;
  flock)
    exec /usr/bin/flock "$@"
    ;;
  test)
    case "${1:-} ${2:-}" in
      "-s /var/run/sshd-bootstrap-deadman.atjob") test -s "$STATE_FILE" ;;
      "-d /var/backups/sshd-bootstrap") exit 0 ;;
      "-d /etc/ssh/sshd_config.d") exit 0 ;;
      "-d /etc/systemd/system/ssh.socket.d"|"-d /etc/systemd/system/sshd.socket.d") exit 1 ;;
      "-s "*) exit 0 ;;
      "-f "*) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  cat)
    [ "${1:-}" = "/var/run/sshd-bootstrap-deadman.atjob" ] || exit 1
    cat "$STATE_FILE"
    ;;
  atrm)
    if [ -n "${FAKE_ATRM_SLEEP:-}" ]; then
      printf 'atrm-start %s\n' "${1:-}" >>"$COMMAND_LOG"
      sleep "$FAKE_ATRM_SLEEP"
      printf 'atrm-end %s\n' "${1:-}" >>"$COMMAND_LOG"
    fi
    [ "${FAKE_ATRM_FAIL:-}" != yes ]
    ;;
  at)
    rollback_command="$(cat)"
    printf 'at-command %s\n' "$rollback_command" >>"$COMMAND_LOG"
    if [ "${FAKE_AT_FAIL:-}" = yes ]; then
      echo "at: simulated scheduling failure" >&2
      exit 1
    fi
    echo "job $FAKE_JOB_ID at Tue Jul 22 00:00:00 2026"
    ;;
  tee)
    append=0
    if [ "${1:-}" = "-a" ]; then
      append=1
      shift
    fi
    target="${1:-}"
    content="$(cat)"
    case "$target" in
      /var/run/sshd-bootstrap-deadman.atjob.tmp.*)
        printf '%s\n' "$content" >"$STATE_FILE.tmp"
        ;;
      /var/run/sshd-bootstrap-deadman.atjob)
        printf '%s\n' "$content" >"$STATE_FILE"
        ;;
      *)
        printf 'mutation-tee %s append=%s\n' "$target" "$append" >>"$COMMAND_LOG"
        ;;
    esac
    ;;
  mv)
    case "${1:-} ${2:-}" in
      "/var/run/sshd-bootstrap-deadman.atjob.tmp."*" /var/run/sshd-bootstrap-deadman.atjob")
        mv "$STATE_FILE.tmp" "$STATE_FILE"
        ;;
      *) exit 1 ;;
    esac
    ;;
  rm)
    target="${*: -1}"
    if [ "$target" = /var/run/sshd-bootstrap-deadman.atjob ]; then
      rm -f "$STATE_FILE"
    else
      case "$target" in
        /var/run/sshd-bootstrap-deadman.atjob.tmp.*) rm -f "$STATE_FILE.tmp" ;;
      esac
    fi
    ;;
  sh)
    echo "$FAKE_LATEST_BACKUP"
    ;;
  grep)
    exit 0
    ;;
  tar)
    case "${1:-}" in
      czf) exit 0 ;;
      xzf) [ "${FAKE_RESTORE_FAIL:-}" != yes ] ;;
      tzf) exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  sshd)
    count=0
    [ ! -s "$SSHD_COUNT" ] || count="$(cat "$SSHD_COUNT")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$SSHD_COUNT"
    if [ "${FAKE_SSHD_FAIL_ONCE:-}" = yes ] && [ "$count" -eq 1 ]; then
      exit 1
    fi
    ;;
  ss)
    echo "LISTEN 0 128 0.0.0.0:22022 0.0.0.0:*"
    ;;
  systemctl)
    if [ "${1:-}" = is-active ]; then
      case "${*: -1}" in
        atd) exit 0 ;;
        *) exit 1 ;;
      esac
    fi
    exit 0
    ;;
  mkdir|chmod)
    ;;
  *)
    echo "unexpected sudo command: $command_name $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/id" "$FAKE_BIN/at" "$FAKE_BIN/date" "$FAKE_BIN/sudo"

# Scheduling must succeed and the exact job/backup record must be durable before mutation.
reset_case
run_apply
assert_status 0
BACKUP_FILE="$(sed -n '2p' "$STATE_FILE")"
[ "$(sed -n '1p' "$STATE_FILE")" = 101 ] || fail "record does not contain scheduled job ID"
case "$BACKUP_FILE" in
  /var/backups/sshd-bootstrap/sshd-*.tar.gz) ;;
  *) fail "record does not contain exact backup path: $(cat "$STATE_FILE")" ;;
esac
assert_log_contains "at-command bash $ROOT_DIR/scripts/08-ssh-harden.sh rollback --auto --backup-file $BACKUP_FILE"
assert_before "mv /var/run/sshd-bootstrap-deadman.atjob.tmp." "mutation-tee /etc/ssh/sshd_config.d/00-server-bootstrap.conf"

# A scheduling failure cannot reach any live SSH mutation.
reset_case
export FAKE_AT_FAIL=yes
run_apply
[ "$STATUS" -ne 0 ] || fail "scheduling failure returned success"
assert_log_excludes "mutation-tee /etc/ssh/"
assert_log_excludes "systemctl reload"
[ ! -e "$STATE_FILE" ] || fail "scheduling failure left a deadman record"

# An unresolved prior job blocks repeated apply before scheduling or mutation.
reset_case
write_new_record 42 /var/backups/sshd-bootstrap/sshd-old.tar.gz
export FAKE_ATRM_FAIL=yes
run_apply
[ "$STATUS" -ne 0 ] || fail "prior cancellation failure returned success"
[ "$(sed -n '1p' "$STATE_FILE")" = 42 ] || fail "prior record was not preserved"
assert_log_contains "atrm 42"
assert_log_excludes "at now + 5 minutes"
assert_log_excludes "mutation-tee /etc/ssh/"

# Successful repeated apply cancels the old job before arming and mutating the new state.
reset_case
run_apply
assert_status 0
FIRST_BACKUP="$(sed -n '2p' "$STATE_FILE")"
: >"$COMMAND_LOG"
export FAKE_JOB_ID=202
run_apply
assert_status 0
[ "$(sed -n '1p' "$STATE_FILE")" = 202 ] || fail "new apply did not replace the cancelled record"
SECOND_BACKUP="$(sed -n '2p' "$STATE_FILE")"
[ "$FIRST_BACKUP" != "$SECOND_BACKUP" ] || fail "rapid repeated apply reused the prior backup path"
assert_before "atrm 101" "at now + 5 minutes"
assert_before "atrm 101" "mutation-tee /etc/ssh/sshd_config.d/00-server-bootstrap.conf"

# Confirm is successful only when cancellation is proven; uncertainty preserves state.
reset_case
write_new_record 42 /var/backups/sshd-bootstrap/sshd-confirm.tar.gz
export FAKE_ATRM_FAIL=yes
run_ssh confirm
[ "$STATUS" -ne 0 ] || fail "confirm swallowed cancellation failure"
[ -s "$STATE_FILE" ] || fail "confirm removed state after cancellation failure"

# Manual rollback restores the recorded backup and retains state on cancellation failure.
reset_case
write_new_record 42 /var/backups/sshd-bootstrap/sshd-manual.tar.gz
export FAKE_ATRM_FAIL=yes
run_ssh rollback
[ "$STATUS" -ne 0 ] || fail "manual rollback swallowed cancellation failure"
assert_log_contains "tar xzf /var/backups/sshd-bootstrap/sshd-manual.tar.gz -C /"
[ -s "$STATE_FILE" ] || fail "manual rollback removed fallback state after cancellation failure"

# Automatic rollback consumes its explicit matching backup and never cancels itself.
reset_case
write_new_record 42 /var/backups/sshd-bootstrap/sshd-auto.tar.gz
run_ssh rollback --auto --backup-file /var/backups/sshd-bootstrap/sshd-auto.tar.gz
assert_status 0
assert_log_contains "tar xzf /var/backups/sshd-bootstrap/sshd-auto.tar.gz -C /"
assert_log_excludes "atrm 42"
[ ! -e "$STATE_FILE" ] || fail "completed automatic rollback left its matching state record"

# A stale automatic command cannot restore once a newer backup owns the record.
reset_case
write_new_record 202 /var/backups/sshd-bootstrap/sshd-new.tar.gz
run_ssh rollback --auto --backup-file /var/backups/sshd-bootstrap/sshd-old.tar.gz
assert_status 0
assert_log_excludes "tar xzf /var/backups/sshd-bootstrap/sshd-old.tar.gz -C /"
[ "$(sed -n '2p' "$STATE_FILE")" = /var/backups/sshd-bootstrap/sshd-new.tar.gz ] ||
  fail "stale automatic rollback changed the newer owner's record"

# Once mutation starts, any failure restores the exact backup paired with the armed job.
reset_case
export FAKE_SSHD_FAIL_ONCE=yes
run_apply
[ "$STATUS" -ne 0 ] || fail "post-mutation sshd validation failure returned success"
BACKUP_FILE="$(sed -n '2p' "$STATE_FILE" 2>/dev/null || true)"
[ -n "$BACKUP_FILE" ] || BACKUP_FILE="$(grep -o '/var/backups/sshd-bootstrap/sshd-[^ ]*\.tar\.gz' "$COMMAND_LOG" | head -1)"
assert_log_contains "tar xzf $BACKUP_FILE -C /"
assert_before "at now + 5 minutes" "mutation-tee /etc/ssh/sshd_config.d/00-server-bootstrap.conf"

# A failed restore attempt must retain the armed job and matching state as fallback.
reset_case
export FAKE_SSHD_FAIL_ONCE=yes
export FAKE_RESTORE_FAIL=yes
run_apply
[ "$STATUS" -ne 0 ] || fail "failed restore path returned success"
[ -s "$STATE_FILE" ] || fail "failed restore discarded its remaining automatic fallback"
assert_log_excludes "atrm 101"

if run_second_pass_case legacy_auto_no_record; then
  reset_case
  run_ssh rollback --auto
  assert_status 0
  assert_log_excludes "tar xzf"
  [ ! -e "$STATE_FILE" ] || fail "legacy auto without a record created state"
fi

if run_second_pass_case legacy_auto_one_line; then
  reset_case
  printf '42\n' >"$STATE_FILE"
  run_ssh rollback --auto
  assert_status 0
  assert_log_contains "tar xzf $FAKE_LATEST_BACKUP -C /"
  [ ! -e "$STATE_FILE" ] || fail "legacy one-line auto did not remove the consumed record"
fi

if run_second_pass_case legacy_auto_new_record; then
  reset_case
  write_new_record 42 /var/backups/sshd-bootstrap/sshd-new-format.tar.gz
  run_ssh rollback --auto
  assert_status 0
  assert_log_excludes "tar xzf"
  [ "$(sed -n '2p' "$STATE_FILE")" = /var/backups/sshd-bootstrap/sshd-new-format.tar.gz ] ||
    fail "legacy auto changed a new-format record"
fi

if run_second_pass_case missing_confirm; then
  reset_case
  run_ssh confirm
  [ "$STATUS" -ne 0 ] || fail "confirm without an armed record returned success"
fi

if run_second_pass_case auto_before_confirm; then
  reset_case
  write_new_record 42 /var/backups/sshd-bootstrap/sshd-auto-first.tar.gz
  run_ssh rollback --auto --backup-file /var/backups/sshd-bootstrap/sshd-auto-first.tar.gz
  assert_status 0
  run_ssh confirm
  [ "$STATUS" -ne 0 ] || fail "confirm succeeded after automatic rollback consumed the record"
fi

if run_second_pass_case manual_ownership; then
  reset_case
  write_new_record 42 /var/backups/sshd-bootstrap/sshd-manual-owner.tar.gz
  export FAKE_ATRM_FAIL=yes
  run_ssh rollback
  [ "$STATUS" -ne 0 ] || fail "manual rollback lost the cancellation failure"
  assert_before "atrm 42" "tar xzf /var/backups/sshd-bootstrap/sshd-manual-owner.tar.gz -C /"
  [ "$(sed -n '4p' "$STATE_FILE")" = manual-restored ] ||
    fail "manual rollback did not persist harmless post-restore ownership"
  : >"$COMMAND_LOG"
  unset FAKE_ATRM_FAIL
  run_ssh rollback --auto --backup-file /var/backups/sshd-bootstrap/sshd-manual-owner.tar.gz
  assert_status 0
  assert_log_excludes "tar xzf"
fi

if run_second_pass_case absolute_deadline; then
  reset_case
  run_apply
  assert_status 0
  [ "$(sed -n '3p' "$STATE_FILE")" = 2000000280 ] ||
    fail "armed deadline does not match GNU at minute truncation"
  [ "$(sed -n '4p' "$STATE_FILE")" = armed ] ||
    fail "armed record does not persist its ownership state"
fi

if run_second_pass_case manual_restore_failed; then
  reset_case
  FAILED_BACKUP=/var/backups/sshd-bootstrap/sshd-manual-retry.tar.gz
  write_new_record 42 "$FAILED_BACKUP"
  export FAKE_RESTORE_FAIL=yes
  run_ssh rollback
  [ "$STATUS" -ne 0 ] || fail "failed manual restore returned success"
  assert_before "atrm 42" "tar xzf $FAILED_BACKUP -C /"
  [ "$(sed -n '2p' "$STATE_FILE")" = "$FAILED_BACKUP" ] ||
    fail "failed manual restore lost its exact backup"
  [ "$(sed -n '4p' "$STATE_FILE")" = manual-restore-failed ] ||
    fail "cancelled job with failed restore remained falsely armed"

  unset FAKE_RESTORE_FAIL
  : >"$COMMAND_LOG"
  run_ssh deadline
  [ "$STATUS" -ne 0 ] || fail "deadline accepted manual-restore-failed state"
  run_ssh confirm
  [ "$STATUS" -ne 0 ] || fail "confirm accepted manual-restore-failed state"
  run_apply
  [ "$STATUS" -ne 0 ] || fail "apply replaced manual-restore-failed state"
  [ "$(sed -n '4p' "$STATE_FILE")" = manual-restore-failed ] ||
    fail "blocked transitions changed manual-restore-failed state"
  assert_log_excludes "atrm 42"
  assert_log_excludes "mutation-tee /etc/ssh/"

  : >"$COMMAND_LOG"
  run_ssh rollback
  assert_status 0
  assert_log_contains "tar xzf $FAILED_BACKUP -C /"
  assert_log_excludes "atrm 42"
  [ ! -e "$STATE_FILE" ] || fail "successful manual retry retained failed-restore state"
fi

if run_second_pass_case serialized_ownership; then
  reset_case
  write_new_record 42 /var/backups/sshd-bootstrap/sshd-serialized.tar.gz
  export FAKE_ATRM_SLEEP=0.5
  FIRST_OUTPUT="$TMP_DIR/first-transition.out"
  SECOND_OUTPUT="$TMP_DIR/second-transition.out"
  start_ssh_process "$FIRST_OUTPUT" confirm
  FIRST_PID=$STARTED_PID
  for _ in $(seq 1 100); do
    grep -Fq 'atrm-start 42' "$COMMAND_LOG" && break
    sleep 0.01
  done
  grep -Fq 'atrm-start 42' "$COMMAND_LOG" || fail "first transition never reached cancellation"
  start_ssh_process "$SECOND_OUTPUT" confirm
  SECOND_PID=$STARTED_PID
  sleep 0.1
  [ ! -s "$SECOND_OUTPUT" ] || fail "second phase-08 transition entered while the first owned state"
  set +e
  wait "$FIRST_PID"
  FIRST_STATUS=$?
  wait "$SECOND_PID"
  SECOND_STATUS=$?
  set -e
  [ "$FIRST_STATUS" -eq 0 ] || fail "first serialized transition failed"
  [ "$SECOND_STATUS" -ne 0 ] || fail "second confirm did not observe the first transition's consumed state"
fi

echo "ssh deadman lifecycle tests passed"
