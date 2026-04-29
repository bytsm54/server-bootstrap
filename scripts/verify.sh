#!/usr/bin/env bash
# verify.sh — 总检查, 打印一段摘要供 agent 转述给用户

# 不用 -e: 我们要把所有项都跑一遍, 不在中途 abort
# 不用 -u: nvm.sh 在 set -u 下会因 PROVIDED_VERSION 等未初始化变量挂掉
set -o pipefail

ok()   { printf '  ✅ %s\n' "$*"; }
miss() { printf '  ❌ %s\n' "$*"; }
warn() { printf '  ⚠️  %s\n' "$*"; }

echo "=========================="
echo " server-bootstrap verify"
echo "=========================="

# hostname / timezone（信息性, 不算成败）
HOST="$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || echo '?')"
TZ_NOW="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '?')"
ok "hostname:   $HOST"
ok "timezone:   $TZ_NOW ($(date '+%Y-%m-%d %H:%M:%S %z'))"

# nvm + node
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" 2>/dev/null

if command -v node >/dev/null 2>&1; then
  ok "Node:       $(node --version)"
else
  miss "Node:       未找到（试 source ~/.nvm/nvm.sh 或用 with-env.sh 包装）"
fi

if command -v npm >/dev/null 2>&1; then
  ok "npm:        $(npm --version)  registry=$(npm config get registry)"
else
  miss "npm:        未找到"
fi

# claude
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
if command -v claude >/dev/null 2>&1; then
  ok "Claude Code: $(claude --version 2>/dev/null || echo 'version unknown')"
else
  miss "Claude Code: 未找到（应在 ~/.local/bin/claude）"
fi

if command -v codex >/dev/null 2>&1; then
  ok "Codex:       $(codex --version 2>/dev/null | head -1 || echo 'version unknown')"
else
  miss "Codex:       未找到（应通过 npm install -g @openai/codex 装好）"
fi

# git identity
GN="$(git config --global user.name  2>/dev/null || true)"
GE="$(git config --global user.email 2>/dev/null || true)"
if [ -n "$GN" ] && [ -n "$GE" ]; then
  ok "git:        $GN <$GE>"
else
  miss "git:        全局身份未配置（跑 05-git-identity.sh）"
fi

# plugins / skills 统计
PLUGINS_FILE="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$PLUGINS_FILE" ]; then
  COUNT="$(python3 -c "import json,sys; d=json.load(open('$PLUGINS_FILE')); print(len(d.get('plugins',[])))" 2>/dev/null || echo '?')"
  ok "Plugins:    $COUNT installed"
else
  warn "Plugins:    无 installed_plugins.json（可能没装过 plugin, 或 Claude Code 还没初始化）"
fi

# skills 实际落地的目录可能是 ~/.agents/skills (新版 npx skills) 或 ~/.claude/skills (老版)
SKILLS_FOUND=0
for SKILLS_DIR in "$HOME/.agents/skills" "$HOME/.claude/skills"; do
  if [ -d "$SKILLS_DIR" ]; then
    COUNT="$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | wc -l | tr -d ' ')"
    [ "$COUNT" -gt 0 ] && ok "Skills:     $COUNT in $SKILLS_DIR" && SKILLS_FOUND=1
  fi
done
[ "$SKILLS_FOUND" -eq 0 ] && warn "Skills:     ~/.agents/skills 和 ~/.claude/skills 都没找到"

# codex skill 软链 (07-plugins-skills 装完后建的)
CODEX_SKILLS="$HOME/.codex/skills"
if [ -d "$CODEX_SKILLS" ]; then
  CODEX_COUNT="$(find "$CODEX_SKILLS" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) | wc -l | tr -d ' ')"
  ok "Codex skills: $CODEX_COUNT in $CODEX_SKILLS (链向 ~/.agents/skills/)"
fi

# bun（claude-mem 等 plugin 依赖）
if [ -x "$HOME/.bun/bin/bun" ]; then
  ok "bun:        $("$HOME/.bun/bin/bun" --version)"
  # 校验三个 rc 文件都有 bun PATH 注入
  MISSING_RC=""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.zshenv"; do
    if [ -f "$rc" ] && ! grep -q 'server-bootstrap:bun-path' "$rc" 2>/dev/null; then
      MISSING_RC="$MISSING_RC $(basename "$rc")"
    fi
  done
  if [ -n "$MISSING_RC" ]; then
    warn "bun PATH 缺失 rc 文件:$MISSING_RC（claude-mem hook 可能找不到 bun）"
  fi
elif command -v bun >/dev/null 2>&1; then
  ok "bun:        $(bun --version) (非 ~/.bun, 自定义安装位置)"
fi

# uv（如果项目用了 Python）
if command -v uv >/dev/null 2>&1; then
  ok "uv:         $(uv --version)"
fi

# zsh（仅 install_zsh 用了才报）
if command -v zsh >/dev/null 2>&1; then
  USER_SHELL="$(getent passwd "$(id -un)" | cut -d: -f7)"
  if [ "$USER_SHELL" = "$(command -v zsh)" ]; then
    ok "zsh:        $(zsh --version | awk '{print $2}') (默认 shell)"
  else
    ok "zsh:        $(zsh --version | awk '{print $2}') (非默认, 默认是 $USER_SHELL)"
  fi
  # 当前 ZSH_THEME（如果 ~/.zshrc 有）
  if [ -f "$HOME/.zshrc" ] && grep -qE '^ZSH_THEME=' "$HOME/.zshrc"; then
    THEME="$(grep -m1 -E '^ZSH_THEME=' "$HOME/.zshrc" | sed -E 's/^ZSH_THEME="?([^"]*)"?.*/\1/')"
    ok "zsh theme:  $THEME"
  fi
fi

# sshd 当前实际监听的端口（仅当 phase 08 用了才有意义）
if command -v ss >/dev/null 2>&1; then
  PORTS="$(ss -ltnH 'sport = :22 or sport > :1024' 2>/dev/null \
            | awk '{print $4}' | awk -F: '{print $NF}' \
            | sort -u | grep -E '^[0-9]+$' \
            | tr '\n' ',' | sed 's/,$//')"
  # 通过 sshd 进程过滤
  SSHD_PORTS="$(ss -ltnpH 2>/dev/null | grep -i sshd \
                | awk '{print $4}' | awk -F: '{print $NF}' \
                | sort -u | tr '\n' ',' | sed 's/,$//')"
  if [ -n "$SSHD_PORTS" ]; then
    ok "sshd:       listening on ${SSHD_PORTS}"
  fi
fi

# deadman 状态（如果有挂起的 at 任务, 提醒用户）
if [ -f /var/run/sshd-bootstrap-deadman.atjob ] || sudo test -f /var/run/sshd-bootstrap-deadman.atjob 2>/dev/null; then
  warn "SSH:        发现挂起的 deadman 任务 — 你应该跑 phase 08 confirm 或 rollback"
fi

# fail2ban（仅当装了才报）
if command -v fail2ban-client >/dev/null 2>&1; then
  if sudo systemctl is-active --quiet fail2ban 2>/dev/null; then
    F2B_PORT="$(sudo awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/ /,"",$2); print $2; exit}' /etc/fail2ban/jail.d/sshd.local 2>/dev/null || true)"
    if [ -n "$F2B_PORT" ]; then
      ok "fail2ban:   active, sshd jail 监听端口 $F2B_PORT"
    else
      ok "fail2ban:   active"
    fi
  else
    warn "fail2ban:   已装但未运行（sudo systemctl start fail2ban）"
  fi
fi

echo "=========================="
echo " done"
echo "=========================="
