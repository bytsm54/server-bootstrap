#!/usr/bin/env bash
# bootstrap.sh — 零依赖一键入口, 用法：
#   curl -fsSL https://raw.githubusercontent.com/bytsm54/server-bootstrap/main/scripts/bootstrap.sh | bash
#
# 做什么：
#   1) clone 本仓库到 ~/server-bootstrap（已存在则更新）
#   2) 跑 02-base-deps.sh → 03-node.sh → 04-claude-code.sh
#   3) 打印下一步指引
#
# 不做什么：
#   - 不配 git 身份（phase 05, 在 claude 会话里完成）
#   - 不装项目（phase 06, 可选）
#   - 不装 plugin / skill（phase 07, 可选）
#   - 不动 sshd / 防火墙
#
# 输出策略：每个 phase 的过程日志收进临时文件, 屏幕只显示最终结果（✅/⚠️ 行）。
# phase 失败时再 dump 完整日志便于排错。

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/bytsm54/server-bootstrap.git}"
REPO_DIR="${REPO_DIR:-$HOME/server-bootstrap}"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

# 跑一个 phase: 标题打到屏幕, 过程日志收进临时文件, 成功只展示 ✅/⚠️ 行, 失败 dump 全日志
run_phase() {
  local label="$1"; shift
  local logfile
  logfile="$(mktemp)"
  printf '\033[1;34m[%s]\033[0m\n' "$label"
  if "$@" >"$logfile" 2>&1; then
    grep -E '✅|⚠️' "$logfile" || true
    rm -f "$logfile"
  else
    printf '\033[1;31m[%s] 失败, 完整日志:\033[0m\n' "$label"
    cat "$logfile"
    rm -f "$logfile"
    exit 1
  fi
}

# --- 1. 必要的最小工具集（curl 自身已经在跑, 这里只确认 git）
if ! command -v git >/dev/null 2>&1; then
  log "安装 git + curl + ca-certificates"
  if ! command -v sudo >/dev/null 2>&1; then
    die "既没有 git 也没有 sudo, 需要 root / 手动装 git 后重跑"
  fi
  sudo apt-get update -y >/dev/null
  sudo apt-get install -y --no-install-recommends git curl ca-certificates >/dev/null
fi

# --- 2. clone / update 仓库
if [ -d "$REPO_DIR/.git" ]; then
  log "更新仓库 $REPO_DIR"
  git -C "$REPO_DIR" fetch --quiet origin
  git -C "$REPO_DIR" pull --ff-only --quiet || warn "pull 失败（本地有改动?）, 继续"
else
  log "克隆仓库到 $REPO_DIR"
  git clone --quiet --depth=1 "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true

# --- 2.5. 注册到 Claude 技能目录, 否则 claude 启动后发现不到 server-bootstrap 这个 SKILL
SKILLS_DIR="$HOME/.claude/skills"
SKILL_LINK="$SKILLS_DIR/server-bootstrap"
mkdir -p "$SKILLS_DIR"
if [ -L "$SKILL_LINK" ]; then
  if [ "$(readlink -f "$SKILL_LINK" 2>/dev/null || readlink "$SKILL_LINK")" != "$REPO_DIR" ]; then
    rm -f "$SKILL_LINK"
    ln -s "$REPO_DIR" "$SKILL_LINK"
    log "修正 SKILL 软链 → $REPO_DIR"
  fi
elif [ -e "$SKILL_LINK" ]; then
  warn "$SKILL_LINK 已存在且不是软链, 跳过 SKILL 注册"
else
  ln -s "$REPO_DIR" "$SKILL_LINK"
  log "注册 SKILL → $SKILL_LINK"
fi

# --- 3. 三个核心 phase
run_phase "Phase 02 — apt 基础依赖" \
  bash "$REPO_DIR/scripts/02-base-deps.sh"

run_phase "Phase 03 — Node (nvm)" \
  bash "$REPO_DIR/scripts/03-node.sh" --node-version "${NODE_VERSION:-lts}" --npm-registry "${NPM_REGISTRY:-china}"

run_phase "Phase 04 — Claude Code CLI" \
  bash "$REPO_DIR/scripts/04-claude-code.sh" --method "${CLAUDE_INSTALL_METHOD:-auto}" ${CLAUDE_VERSION:+--version "$CLAUDE_VERSION"}

run_phase "Phase 04a — Codex CLI (npm -g @openai/codex)" \
  bash "$REPO_DIR/scripts/lib/with-env.sh" -- bash "$REPO_DIR/scripts/04a-codex.sh"

run_phase "Phase 04b — RTK + Claude/Codex 规则注入" \
  bash "$REPO_DIR/scripts/04b-rtk.sh"

# --- 4. 总结 & 下一步
NODE_VER="(未加载 nvm)"
CLAUDE_VER="(未加载)"
CODEX_VER="(未装)"
RTK_VER="(未装)"
[ -s "$HOME/.nvm/nvm.sh" ] && (
  . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1
  command -v node >/dev/null 2>&1 && node --version
) >/tmp/.bootstrap-node-ver 2>/dev/null && NODE_VER=$(cat /tmp/.bootstrap-node-ver) && rm -f /tmp/.bootstrap-node-ver
[ -x "$HOME/.local/bin/claude" ] && CLAUDE_VER=$("$HOME/.local/bin/claude" --version 2>/dev/null || echo "已装")
CODEX_VER=$(bash "$REPO_DIR/scripts/lib/with-env.sh" -- codex --version 2>/dev/null | head -1 || echo "(未装)")
# rtk 装完后可能在 ~/.local/bin / ~/.cargo/bin / ~/.rtk/bin, 总结时把候选目录都加进 PATH 再查
for d in "$HOME/.local/bin" "$HOME/.cargo/bin" "$HOME/.rtk/bin"; do
  case ":$PATH:" in *":$d:"*) ;; *) [ -d "$d" ] && export PATH="$d:$PATH" ;; esac
done
command -v rtk >/dev/null 2>&1 && RTK_VER=$(rtk --version 2>/dev/null | head -1 || echo "已装")

printf '\n\033[1;32m✅ bootstrap.sh 完成\033[0m\n\n'

cat <<EOF
已装:
  Node:        $NODE_VER
  Claude Code: $CLAUDE_VER
  Codex:       $CODEX_VER
  RTK:         $RTK_VER
  SKILL:       $SKILL_LINK

下一步:
  1) 在当前 shell 加载 PATH:
       source ~/.nvm/nvm.sh && export PATH="\$HOME/.local/bin:\$PATH"
  2) 起 claude:
       claude
  3) 进会话后说: "执行 server-bootstrap, git_user_name=..., git_user_email=..."
EOF
