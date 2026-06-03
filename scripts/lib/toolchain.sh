#!/usr/bin/env bash
# Shared helpers that keep bootstrap-managed CLIs on one Node/npm toolchain.

toolchain_realpath() {
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

path_prepend_once() {
  local dir="$1"
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
}

path_append_once() {
  local dir="$1"
  case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$PATH:$dir" ;; esac
}

cleanup_conflicting_local_node_shims() {
  local nvm_bin="$1" tool local_path target expected
  for tool in node npm npx; do
    local_path="$HOME/.local/bin/$tool"
    expected="$nvm_bin/$tool"
    [ -e "$local_path" ] || continue

    if [ -L "$local_path" ]; then
      target="$(toolchain_realpath "$local_path")"
      if [ "$target" != "$(toolchain_realpath "$expected")" ]; then
        rm -f "$local_path"
      fi
      continue
    fi

    printf 'conflicting non-symlink exists: %s\n' "$local_path" >&2
    printf 'move it aside before running server-bootstrap so nvm owns node/npm/npx\n' >&2
    return 1
  done
}

ensure_managed_node_toolchain() {
  local nvm_bin="$1"
  mkdir -p "$HOME/.local/bin"
  cleanup_conflicting_local_node_shims "$nvm_bin" || return 1
  path_prepend_once "$nvm_bin"
  path_append_once "$HOME/.local/bin"
}

ensure_codex_shim_for_prefix() {
  local prefix="$1" target="$1/bin/codex" shim="$HOME/.local/bin/codex"
  if [ ! -x "$target" ]; then
    printf 'codex target is not executable: %s\n' "$target" >&2
    return 1
  fi

  mkdir -p "$HOME/.local/bin"
  if [ -e "$shim" ] && [ ! -L "$shim" ]; then
    printf 'conflicting non-symlink exists: %s\n' "$shim" >&2
    printf 'move it aside before running server-bootstrap so codex can point at npm prefix\n' >&2
    return 1
  fi
  ln -sfn "$target" "$shim"
}
