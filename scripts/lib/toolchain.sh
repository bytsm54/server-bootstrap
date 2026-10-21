#!/usr/bin/env bash
# Environment-only helpers: never remove or rewrite an existing executable.
path_prepend_once() {
  local dir="$1" part next=''
  local -a parts
  IFS=: read -r -a parts <<< "$PATH"
  for part in "${parts[@]}"; do
    [ "$part" = "$dir" ] || next="${next:+$next:}$part"
  done
  export PATH="$dir${next:+:$next}"
}
path_append_once() {
  case ":$PATH:" in *":$1:"*) ;; *) export PATH="$PATH:$1" ;; esac
}
ensure_managed_node_toolchain() { path_prepend_once "$1"; path_append_once "$HOME/.local/bin"; }
