#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN="$TMP_DIR/fake-bin"
COMMAND_LOG="$TMP_DIR/commands.log"
mkdir -p "$FAKE_BIN"
: >"$COMMAND_LOG"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for command_name in curl git at; do
  printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/$command_name"
  chmod +x "$FAKE_BIN/$command_name"
done

cat >"$FAKE_BIN/dpkg" <<'EOF'
#!/bin/bash
exit 0
EOF

cat >"$FAKE_BIN/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -u ]; then
  echo 1000
  exit 0
fi
exit 1
EOF

cat >"$FAKE_BIN/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$COMMAND_LOG"
if [ "${1:-}" = apt-get ] && [ "${2:-}" = install ]; then
  case " $* " in
    *" python3 "*)
      printf '#!/bin/bash\nexit 0\n' >"$FAKE_BIN/python3"
      /bin/chmod +x "$FAKE_BIN/python3"
      ;;
  esac
fi
exit 0
EOF

chmod +x "$FAKE_BIN/dpkg" "$FAKE_BIN/id" "$FAKE_BIN/sudo"

env \
  COMMAND_LOG="$COMMAND_LOG" \
  FAKE_BIN="$FAKE_BIN" \
  PATH="$FAKE_BIN" \
  /bin/bash "$ROOT_DIR/scripts/02-base-deps.sh"

grep -Fqx 'apt-get update -y' "$COMMAND_LOG" ||
  fail "missing python3 did not trigger apt metadata refresh"
grep -Fqx 'apt-get install -y --no-install-recommends python3' "$COMMAND_LOG" ||
  fail "base dependencies did not install the missing python3 runtime"
[ -x "$FAKE_BIN/python3" ] || fail "python3 post-install verification did not run"

echo "base dependency python3 test passed"
