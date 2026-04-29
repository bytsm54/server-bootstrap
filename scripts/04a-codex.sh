#!/usr/bin/env bash
# 04a-codex.sh — 装 OpenAI Codex CLI (npm install -g @openai/codex)
#
# 用法:
#   bash 04a-codex.sh
#
# 行为:
#   - 已装且能 codex --version → 跳过
#   - 未装 → npm install -g @openai/codex, 然后校验
#
# 依赖:
#   - 必须先跑 phase 03 (nvm + Node + npm)
#   - 必须用 with-env.sh 包装调用, 否则 nvm 没 source, npm 不在 PATH:
#       bash lib/with-env.sh -- bash 04a-codex.sh

set -euo pipefail

log()  { printf '\033[1;34m[04a-codex]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

if ! command -v npm >/dev/null 2>&1; then
  err "npm 不在 PATH"
  err "解决: 用 with-env.sh 包装 (bash lib/with-env.sh -- bash 04a-codex.sh)"
  err "      或先跑 phase 03 (bash 03-node.sh)"
  exit 1
fi

if command -v codex >/dev/null 2>&1; then
  ok "codex 已装: $(codex --version 2>&1 | head -1)"
  exit 0
fi

log "npm install -g @openai/codex"
npm install -g @openai/codex

if ! command -v codex >/dev/null 2>&1; then
  err "codex 装完仍找不到 — 检查 npm prefix: $(npm config get prefix 2>/dev/null || echo '?')"
  exit 1
fi

ok "codex: $(codex --version 2>&1 | head -1)"

# 提前 mkdir ~/.codex/skills, 让 codex 一装完就有"插槽"
# (phase 07 装完 Claude skill 后会往这个目录里逐项软链, 但 phase 07 可能被
#  用户跳过, 或源目录为空, 逻辑就不会进入 mkdir 那段。在这里 mkdir 保证目录
#  始终存在, 用户用 ls 能看见。)
mkdir -p "$HOME/.codex/skills"
ok "已建 ~/.codex/skills/ (phase 07 会往里灌软链)"

log "完成"
