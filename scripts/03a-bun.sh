#!/usr/bin/env bash
# Optional standalone runtime; does not require Node.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/python-env.sh"
if [ ! -x "$HOME/.bun/bin/bun" ]; then
  if ! command -v unzip >/dev/null; then
    init_privilege
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y --no-install-recommends unzip
  fi
  case "$(uname -m)" in
    x86_64) target=bun-linux-x64-baseline ;;
    aarch64|arm64) target=bun-linux-aarch64 ;;
    *) echo 'Bun 不支持此架构' >&2; exit 1 ;;
  esac
  download="$(mktemp -d)"
  trap 'rm -rf "$download"' EXIT
  curl -fsSL --retry 3 "https://github.com/oven-sh/bun/releases/latest/download/$target.zip" -o "$download/bun.zip"
  unzip -q "$download/bun.zip" "$target/bun" -d "$download"
  "$download/$target/bun" --version
  mkdir -p "$HOME/.bun/bin"
  install -m 755 "$download/$target/bun" "$HOME/.bun/bin/bun"
  if [ ! -e "$HOME/.bun/bin/bunx" ] && [ ! -L "$HOME/.bun/bin/bunx" ]; then ln -s bun "$HOME/.bun/bin/bunx"; fi
fi
"$HOME/.bun/bin/bun" --version
ensure_python_env
for rc in .profile .bashrc .zshrc; do
  cat <<'EOF' | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$HOME/$rc" bun-path
export BUN_INSTALL="$HOME/.bun"
case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) export PATH="$PATH:$BUN_INSTALL/bin" ;; esac
EOF
done
