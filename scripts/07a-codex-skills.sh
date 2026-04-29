#!/usr/bin/env bash
# 07a-codex-skills.sh — 把 Claude 的 skill 软链给 codex 共享
#
# 用法:
#   bash 07a-codex-skills.sh
#
# 行为:
#   1. codex 没装 → 跳过, 退出 0
#   2. ~/.codex/skills/ 不存在 → 创建 (04a 已经建过, 这里再保险一次)
#   3. 源目录优先 ~/.agents/skills (新版 npx skills 默认), 回退 ~/.claude/skills
#   4. 源目录为空 → 报告"没有 skill 可链", 退出 0 (用户可能跳过了 phase 07)
#   5. 否则逐项软链: ~/.agents/skills/<name>/ → ~/.codex/skills/<name>
#      - 已是同目标软链 → 跳过
#      - 已是不同目标软链 → 替换
#      - 已存在但不是软链 → 跳过, warn (不破坏 codex 自有 skill)
#
# 顺序约束: 必须在 phase 07 (装 Claude skill) 之后跑, 否则源目录为空。

set -euo pipefail

log()  { printf '\033[1;34m[07a-codex-skills]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }

if ! command -v codex >/dev/null 2>&1; then
  log "codex 未装, 跳过 codex skill 软链 (phase 04a 应该装它, 检查一下)"
  exit 0
fi

DST_DIR="$HOME/.codex/skills"
mkdir -p "$DST_DIR"

# 找 skill 源目录: 优先 ~/.agents/skills (npx skills 默认), 回退 ~/.claude/skills
SRC_DIR=""
for cand in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
  if [ -d "$cand" ] && [ -n "$(ls -A "$cand" 2>/dev/null)" ]; then
    SRC_DIR="$cand"
    break
  fi
done

if [ -z "$SRC_DIR" ]; then
  warn "Claude skill 目录为空 (~/.agents/skills 和 ~/.claude/skills 都没东西)"
  warn "用户可能跳过了 phase 07; codex 暂时没 skill 可共享"
  warn "$DST_DIR 已存在但是空的"
  exit 0
fi

log "源 = $SRC_DIR  →  目标 = $DST_DIR"
LINKED=0
SKIPPED_NONLINK=0
ALREADY_OK=0

for skill_path in "$SRC_DIR"/*; do
  [ -e "$skill_path" ] || continue
  name="$(basename "$skill_path")"
  target="$DST_DIR/$name"

  if [ -L "$target" ]; then
    cur="$(readlink -f "$target" 2>/dev/null || true)"
    new="$(readlink -f "$skill_path" 2>/dev/null || true)"
    if [ "$cur" = "$new" ] && [ -n "$cur" ]; then
      ALREADY_OK=$((ALREADY_OK + 1))
      continue
    fi
    rm -f "$target"
    ln -s "$skill_path" "$target"
    LINKED=$((LINKED + 1))
  elif [ -e "$target" ]; then
    warn "跳过 $name (已存在且不是软链, 不动)"
    SKIPPED_NONLINK=$((SKIPPED_NONLINK + 1))
  else
    ln -s "$skill_path" "$target"
    LINKED=$((LINKED + 1))
  fi
done

ok "完成: $LINKED 新链 / $ALREADY_OK 已就绪 / $SKIPPED_NONLINK 非软链跳过 (in $DST_DIR)"
