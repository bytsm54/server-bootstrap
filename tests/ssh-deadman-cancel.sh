#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/fake-bin"
MANUAL_LOG="$TMP_DIR/manual.log"
AUTO_LOG="$TMP_DIR/auto.log"
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ]; then
  echo 1000
  exit 0
fi
exit 1
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_LOG"

case "${1:-}" in
  sh)
    echo /var/backups/sshd-bootstrap/sshd-test.tar.gz
    ;;
  cat)
    echo 42
    ;;
  test|tar|sshd|systemctl|rm|atrm)
    ;;
  *)
    echo "unexpected sudo command: $*" >&2
    exit 1
    ;;
esac
EOF

chmod +x "$FAKE_BIN/id" "$FAKE_BIN/sudo"
export PATH="$FAKE_BIN:/usr/bin:/bin"

SUDO_LOG="$MANUAL_LOG" bash "$ROOT_DIR/scripts/08-ssh-harden.sh" rollback
SUDO_LOG="$AUTO_LOG" bash "$ROOT_DIR/scripts/08-ssh-harden.sh" rollback --auto

grep -q '^atrm 42$' "$MANUAL_LOG"
if grep -q '^atrm 42$' "$AUTO_LOG"; then
  echo "FAIL: automatic rollback cancelled its own job" >&2
  exit 1
fi

echo "ssh deadman cancellation tests passed"
