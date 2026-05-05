#!/usr/bin/env bash
# 04b-rtk.sh — 装 RTK (Rust Token Killer) 并把对应规则注入 Claude / Codex 的全局指令文件
#
# 用法:
#   bash 04b-rtk.sh
#
# 行为:
#   1. rtk 已在 PATH 且 rtk --version 能跑通 → 跳过安装
#   2. 否则 curl 上游 install.sh | sh
#   3. 把规则行追加到:
#        - ~/.claude/CLAUDE.md   (Claude 全局指令)
#        - ~/.codex/AGENTS.md    (Codex 全局指令)
#      用 marker 注释保证幂等, 重跑只追加一次
#
# 设计:
#   - 安装走官方 install.sh (rtk-ai/rtk, master 分支)
#   - install.sh 可能把二进制装到 ~/.local/bin / ~/.cargo/bin / ~/.rtk/bin 任一位置,
#     校验时把这几个候选目录都加进 PATH 再 command -v
#   - 不强制要求 rtk 被装上：上游 install.sh 失败时本脚本退非零, 让 bootstrap 报错
#
# 不依赖 nvm / npm — 不需要 with-env.sh 包装

set -euo pipefail

log()  { printf '\033[1;34m[04b-rtk]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

# 把 rtk 可能落地的目录都加进 PATH, 不污染调用方 (本脚本是子 shell)
for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.rtk/bin" "$HOME/.bun/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && export PATH="$d:$PATH" ;; esac
done

# --- 1. 安装 (幂等)
if command -v rtk >/dev/null 2>&1 && rtk --version >/dev/null 2>&1; then
  ok "rtk 已装: $(rtk --version 2>&1 | head -1)"
else
  log "curl install.sh | sh (https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh)"
  if ! curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh; then
    err "上游 install.sh 失败"
    exit 1
  fi

  # install.sh 装完后再扫一次候选目录, 然后 hash -r 让当前 shell 找新装的二进制
  for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.rtk/bin"; do
    case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && export PATH="$d:$PATH" ;; esac
  done
  hash -r 2>/dev/null || true

  if ! command -v rtk >/dev/null 2>&1; then
    err "install.sh 跑完了但当前 shell 找不到 rtk"
    err "试一下: ls ~/.local/bin/rtk ~/.cargo/bin/rtk ~/.rtk/bin/rtk 2>/dev/null"
    err "确认装到了哪里, 然后 export PATH 把那个目录加进去"
    exit 1
  fi

  ok "rtk 安装完成: $(rtk --version 2>&1 | head -1)"
  ok "位置: $(command -v rtk)"
fi

# --- 2. 注入规则到 Claude / Codex 全局指令文件 (幂等, 用 marker)

append_rule() {
  local file="$1" marker="$2" rule="$3"

  mkdir -p "$(dirname "$file")"

  if [ -f "$file" ] && grep -qF "$marker" "$file" 2>/dev/null; then
    ok "$file 已含 rtk 规则, 跳过"
    return 0
  fi

  log "追加 rtk 规则 → $file"
  # 文件不存在 → touch; 存在但末尾没换行 → 补一个; 再补一个空行隔开
  if [ -f "$file" ] && [ -s "$file" ]; then
    [ -n "$(tail -c1 "$file" 2>/dev/null)" ] && echo "" >> "$file"
    echo "" >> "$file"
  fi
  printf '%s\n%s\n' "$marker" "$rule" >> "$file"
  ok "$file 已追加"
}

CLAUDE_MD="$HOME/.claude/CLAUDE.md"
CODEX_AGENTS="$HOME/.codex/AGENTS.md"

CLAUDE_MARKER="<!-- server-bootstrap:rtk-rule (managed by 04b-rtk.sh, do not edit) -->"
CLAUDE_RULE="- 读取文件和搜索代码时优先使用 shell 命令或 rtk 命令，例如 rtk read、rtk grep、rtk git status、rtk git diff。"

CODEX_MARKER="<!-- server-bootstrap:rtk-rule (managed by 04b-rtk.sh, do not edit) -->"
CODEX_RULE="- 所有会产生长输出的 shell 命令请优先用 rtk：rtk git status、rtk git diff、rtk read、rtk grep、rtk npm test。"

append_rule "$CLAUDE_MD"    "$CLAUDE_MARKER" "$CLAUDE_RULE"
append_rule "$CODEX_AGENTS" "$CODEX_MARKER" "$CODEX_RULE"

log "完成"
