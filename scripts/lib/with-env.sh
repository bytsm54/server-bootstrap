#!/usr/bin/env bash
# with-env.sh — 包装命令, 在执行前 source nvm 并把 ~/.local/bin 加入 PATH
#
# 用法：
#   bash with-env.sh -- <command and args>
#
# 例：
#   bash with-env.sh -- claude --version
#   bash with-env.sh -- npm install -g something
#   bash with-env.sh -- bash 05-git-identity.sh --name foo
#
# 为什么需要：Claude Code 的 Bash tool 每次起新 bash, 不会 source 你的 ~/.zshrc 或
# ~/.bashrc, nvm 不会自动加载, claude 也不在 PATH 里。这个包装解决这两件事。

# 不用 -u: 一些 nvm 内部代码路径（如 PROVIDED_VERSION）在 set -u 下会挂掉。
set -eo pipefail

# --- 加载 nvm（如果存在）
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
fi

# --- 把 ~/.local/bin 加进 PATH（Claude Code 默认装在那里）
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# --- bun（claude-mem 等 plugin 依赖）
if [ -d "$HOME/.bun/bin" ]; then
  export BUN_INSTALL="$HOME/.bun"
  case ":$PATH:" in
    *":$HOME/.bun/bin:"*) ;;
    *) export PATH="$HOME/.bun/bin:$PATH" ;;
  esac
fi

# --- 把 nvm 当前 node 路径暴露给子进程（npm/npx 相关）
if command -v node >/dev/null 2>&1; then
  NODE_BIN="$(dirname "$(command -v node)")"
  case ":$PATH:" in
    *":$NODE_BIN:"*) ;;
    *) export PATH="$NODE_BIN:$PATH" ;;
  esac
fi

# --- 解析参数：支持 `with-env.sh -- cmd args` 也支持 `with-env.sh cmd args`
if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "$#" -eq 0 ]; then
  cat <<'EOF' >&2
with-env.sh: 没有要执行的命令
用法：bash with-env.sh -- <command and args>
例：bash with-env.sh -- claude --version
EOF
  exit 2
fi

exec "$@"
