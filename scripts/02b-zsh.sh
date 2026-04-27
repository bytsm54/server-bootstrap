#!/usr/bin/env bash
# 02b-zsh.sh — 可选 phase：装 zsh + 高亮 / 自动建议 + oh-my-zsh, 设默认 shell
#
# 用法：
#   bash 02b-zsh.sh [--user $(whoami)] [--default-shell yes|no]
#
# 行为：
#   1. apt 装 zsh, zsh-syntax-highlighting, zsh-autosuggestions（已装则跳过）
#   2. 装 oh-my-zsh 到 ~/.oh-my-zsh（用户态, 已存在则跳过, 不会覆盖 ~/.zshrc）
#   3. 启用插件 git/sudo/zsh-syntax-highlighting/zsh-autosuggestions
#   4. 默认 shell 改为 zsh（仅当 --default-shell yes, 默认 yes, 需要 sudo 走 chsh）
#
# 顺序提醒：
#   本 phase 应该在 03-node.sh 之前跑, 这样 nvm 的 ~/.zshrc 注入位于
#   oh-my-zsh 模板之后, 不会被覆盖。

set -euo pipefail

log()  { printf '\033[1;34m[02b-zsh]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

USER_NAME="$(id -un)"
DEFAULT_SHELL="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          USER_NAME="$2"; shift 2 ;;
    --default-shell) DEFAULT_SHELL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--user <name>] [--default-shell yes|no]"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

# --- sudo 前置（只在装 apt 包和 chsh 时用）
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "本 phase 需要 sudo 装 apt 包 + chsh, 但 sudo 不可用"
    exit 1
  fi
  SUDO=(sudo)
else
  SUDO=()
fi

# --- 1. apt 包
PKGS=(zsh zsh-syntax-highlighting zsh-autosuggestions)
MISSING=()
for p in "${PKGS[@]}"; do
  dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
done

if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "zsh 相关 apt 包已齐"
else
  log "apt 安装：${MISSING[*]}"
  "${SUDO[@]}" apt-get update -y
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${MISSING[@]}"
  ok "apt 安装完成"
fi

# --- 2. oh-my-zsh
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
  err "找不到用户 $USER_NAME 的 home 目录"
  exit 1
fi

if [ -d "$USER_HOME/.oh-my-zsh" ]; then
  ok "oh-my-zsh 已装 ($USER_HOME/.oh-my-zsh)"
else
  log "装 oh-my-zsh 到 $USER_HOME/.oh-my-zsh（用户态）"
  # 强制以目标用户身份装；KEEP_ZSHRC=yes 防止覆盖既有 ~/.zshrc
  if [ "$(id -un)" = "$USER_NAME" ]; then
    RUNNER=(env)
  else
    RUNNER=(sudo -u "$USER_NAME" env)
  fi
  "${RUNNER[@]}" \
    HOME="$USER_HOME" \
    ZSH="$USER_HOME/.oh-my-zsh" \
    KEEP_ZSHRC=yes \
    RUNZSH=no \
    CHSH=no \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
  ok "oh-my-zsh 安装完成"
fi

# --- 3. 启用插件（编辑 ~/.zshrc 的 plugins=(...) 行）
ZSHRC="$USER_HOME/.zshrc"
if [ -f "$ZSHRC" ]; then
  WANT_PLUGINS=(git sudo zsh-syntax-highlighting zsh-autosuggestions)
  if grep -qE '^plugins=\(' "$ZSHRC"; then
    CUR_LINE="$(grep -m1 -E '^plugins=\(' "$ZSHRC")"
    NEEDS_UPDATE=0
    for p in "${WANT_PLUGINS[@]}"; do
      grep -qE "(^|\()[[:space:]]+?$p([[:space:]]|\))" <<<"$CUR_LINE" || NEEDS_UPDATE=1
    done
    if [ "$NEEDS_UPDATE" -eq 1 ]; then
      log "更新 ~/.zshrc 的 plugins=(...) 行"
      sed -i.bak -E "s|^plugins=\([^)]*\)|plugins=(${WANT_PLUGINS[*]})|" "$ZSHRC"
      ok "plugins 已设为：${WANT_PLUGINS[*]}（备份在 ~/.zshrc.bak）"
    else
      ok "plugins=() 已包含目标插件"
    fi
  else
    log "在 ~/.zshrc 末尾追加 plugins=(...)"
    {
      echo
      echo "# Added by server-bootstrap 02b-zsh"
      echo "plugins=(${WANT_PLUGINS[*]})"
    } >> "$ZSHRC"
    ok "plugins 已追加"
  fi

  # 让 apt 装的高亮 / 自动建议在 oh-my-zsh 缺失时也能工作（双保险）
  for srcline in \
    "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    "source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
    if ! grep -Fq "$srcline" "$ZSHRC" 2>/dev/null; then
      f="${srcline#source }"
      [ -f "$f" ] && echo "$srcline" >> "$ZSHRC"
    fi
  done
else
  warn "~/.zshrc 不存在（oh-my-zsh 安装异常？）"
fi

# --- 4. 默认 shell
if [ "$DEFAULT_SHELL" = "yes" ]; then
  CURRENT_SHELL="$(getent passwd "$USER_NAME" | cut -d: -f7)"
  TARGET_SHELL="$(command -v zsh)"
  if [ "$CURRENT_SHELL" = "$TARGET_SHELL" ]; then
    ok "默认 shell 已是 zsh"
  else
    log "用 sudo chsh 把 $USER_NAME 的默认 shell 改为 $TARGET_SHELL"
    "${SUDO[@]}" chsh -s "$TARGET_SHELL" "$USER_NAME"
    ok "默认 shell 已设为 zsh（下次登录生效）"
  fi
fi

log "完成"
