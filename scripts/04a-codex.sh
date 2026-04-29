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
# (phase 07a 装完 Claude skill 后会往这个目录里逐项软链, 但 phase 07a 可能被
#  跳过或源目录为空, 软链分支不会进入 mkdir。在这里 mkdir 保证目录始终存在。)
mkdir -p "$HOME/.codex/skills"
ok "已建 ~/.codex/skills/ (phase 07a 会往里灌软链)"

# --- 追加 memories 配置到 ~/.codex/config.toml (幂等, 用 marker 检测)
# 注意: 如果用户预先有 [features] 段, 这里追加会让 TOML 出现重复段; 实践中
# fresh 装完 codex 时 config.toml 一般空 / 不存在, 不冲突。
CONFIG_FILE="$HOME/.codex/config.toml"
MARKER="# server-bootstrap:codex-memories (managed by 04a-codex.sh, do not edit)"

if [ -f "$CONFIG_FILE" ] && grep -qF "$MARKER" "$CONFIG_FILE" 2>/dev/null; then
  ok "config.toml 已含 memories 段, 跳过"
else
  log "追加 memories 配置 → $CONFIG_FILE"
  # 文件已存在且非空, 末尾没换行 → 补一个; 再多补一个空行隔开
  if [ -f "$CONFIG_FILE" ] && [ -s "$CONFIG_FILE" ]; then
    [ -n "$(tail -c1 "$CONFIG_FILE" 2>/dev/null)" ] && echo "" >> "$CONFIG_FILE"
    echo "" >> "$CONFIG_FILE"
  fi
  cat >> "$CONFIG_FILE" <<EOF
$MARKER
[features]
memories = true

[memories]
generate_memories = true
use_memories = true
disable_on_external_context = true
EOF
  ok "memories 配置已追加"
fi

log "完成"
