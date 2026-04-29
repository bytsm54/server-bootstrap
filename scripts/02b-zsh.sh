#!/usr/bin/env bash
# 02b-zsh.sh — 可选 phase：装 zsh + 高亮 / 自动建议 + oh-my-zsh, 设默认 shell
#
# 用法：
#   bash 02b-zsh.sh [--user $(whoami)] [--default-shell yes|no] [--theme <name>]
#
# 行为：
#   1. apt 装 zsh, zsh-syntax-highlighting, zsh-autosuggestions（已装则跳过）
#   2. 装 oh-my-zsh 到 ~/.oh-my-zsh（用户态, 已存在则跳过, 不会覆盖 ~/.zshrc）
#   3. plugins=(git sudo) — 只放真正符合 omz plugin 结构的项
#      apt 装的 zsh-syntax-highlighting / zsh-autosuggestions 落在 /usr/share/, 不是
#      omz plugin 结构, 写进 plugins=() 会触发 "plugin not found" 告警, 因此通过
#      .zshrc 末尾的 source 行加载（见步骤末尾, 这才是真正让功能工作的地方）。
#   4. 设 ZSH_THEME=<theme>（默认 powerlevel10k/powerlevel10k）
#      - 内置主题（agnoster / robbyrussell 等）直接 set
#      - 含 "/" 的自定义主题（如 powerlevel10k/powerlevel10k）会自动 git clone 到
#        ~/.oh-my-zsh/custom/themes/<repo>/, 然后 set 主题路径
#   5. 默认 shell 改为 zsh（仅当 --default-shell yes, 默认 yes, 需要 sudo 走 chsh）
#
# 顺序提醒：
#   本 phase 应该在 03-node.sh 之前跑, 这样 nvm 的 ~/.zshrc 注入位于
#   oh-my-zsh 模板之后, 不会被覆盖。
#
# powerlevel10k 字体提示：
#   p10k 推荐你 *本地终端* 装 MesloLGS NF (Nerd Font), 才能完整显示 icon。
#   下载: https://github.com/romkatv/powerlevel10k/blob/master/font.md
#   首次进交互 zsh 时会跳出 "p10k configure" 向导, 没装 Nerd Font 也能在向导里
#   选 "ASCII only" 风格, 不影响功能。服务器端无需配置, 这是终端字体设置。

set -euo pipefail

log()  { printf '\033[1;34m[02b-zsh]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

USER_NAME="$(id -un)"
DEFAULT_SHELL="yes"
ZSH_THEME_NAME="powerlevel10k/powerlevel10k"

while [ $# -gt 0 ]; do
  case "$1" in
    --user)          USER_NAME="$2"; shift 2 ;;
    --default-shell) DEFAULT_SHELL="$2"; shift 2 ;;
    --theme)         ZSH_THEME_NAME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--user <name>] [--default-shell yes|no] [--theme <name>]"
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
# 注: fonts-powerline 已在 02-base-deps.sh 里装过, 这里不重复
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
TEMPLATE="$USER_HOME/.oh-my-zsh/templates/zshrc.zsh-template"

# 健康检查 + 自愈: .zshrc 必须含 omz 入口 (`export ZSH=` 和 `source $ZSH/oh-my-zsh.sh`)
#
# 失败场景: omz installer 用了 KEEP_ZSHRC=yes (避免覆盖用户自定义 .zshrc)。
# 如果 .zshrc 在 install 前就存在 — 云镜像 / cloud-init / 之前失败的尝试都可能
# 留下一个空的或部分的 .zshrc — installer 走 keep 分支, 不复制模板, .zshrc
# 缺 omz 入口, 后续 zsh 启动看似 "在 zsh 里" 但根本没加载 omz (没主题、没插件、
# 没 ll alias)。这里强制校验, 缺了就以 omz 模板为底重置。
NEEDS_RESET=0
if [ ! -f "$ZSHRC" ]; then
  log ".zshrc 不存在 (omz installer 异常?), 用 omz 模板创建"
  NEEDS_RESET=1
elif ! grep -qE '^[[:space:]]*export[[:space:]]+ZSH=' "$ZSHRC" 2>/dev/null \
   || ! grep -qE 'source[[:space:]]+\$ZSH/oh-my-zsh\.sh' "$ZSHRC" 2>/dev/null; then
  warn ".zshrc 缺 omz 入口 (export ZSH= 或 source \$ZSH/oh-my-zsh.sh)"
  warn "典型成因: omz installer KEEP_ZSHRC=yes 遇到了已存在的部分 .zshrc"
  NEEDS_RESET=1
fi

if [ "$NEEDS_RESET" -eq 1 ]; then
  if [ ! -f "$TEMPLATE" ]; then
    err "omz 模板 $TEMPLATE 不存在 — omz 安装可能失败, 排查后重跑"
    exit 1
  fi
  AS_USER=()
  [ "$(id -un)" != "$USER_NAME" ] && AS_USER=(sudo -u "$USER_NAME")
  if [ -f "$ZSHRC" ]; then
    BACKUP="$ZSHRC.broken-$(date +%Y%m%d-%H%M%S)"
    "${AS_USER[@]}" cp "$ZSHRC" "$BACKUP"
    log "现状备份 → $BACKUP"
  fi
  "${AS_USER[@]}" cp "$TEMPLATE" "$ZSHRC"
  # 模板里 ZSH=$HOME/... 是 shell 变量风格, 跟 omz installer 行为对齐, 写绝对路径
  "${AS_USER[@]}" sed -i.tmp -E "s|^export ZSH=.*$|export ZSH=\"$USER_HOME/.oh-my-zsh\"|" "$ZSHRC"
  "${AS_USER[@]}" rm -f "$ZSHRC.tmp"
  ok ".zshrc 已重置为 omz 模板"
fi

if [ -f "$ZSHRC" ]; then
  # 只把"真 omz plugin"放进 plugins=()
  WANT_PLUGINS=(git sudo)
  # apt 装的两个包名 — 历史上的 02b 把它们错放进 plugins=(), 触发 not found 告警。
  # 现在通过下面的 source 行加载, 因此要从 plugins=() 里剔除（覆盖旧版脚本的产物）。
  BAD_PLUGINS=(zsh-syntax-highlighting zsh-autosuggestions)

  if grep -qE '^plugins=\(' "$ZSHRC"; then
    CUR_LINE="$(grep -m1 -E '^plugins=\(' "$ZSHRC")"
    NEEDS_UPDATE=0
    for p in "${WANT_PLUGINS[@]}"; do
      grep -qE "(^|\()[[:space:]]*$p([[:space:]]|\))" <<<"$CUR_LINE" || NEEDS_UPDATE=1
    done
    for p in "${BAD_PLUGINS[@]}"; do
      if grep -qE "(^|\()[[:space:]]*$p([[:space:]]|\))" <<<"$CUR_LINE"; then
        NEEDS_UPDATE=1
      fi
    done
    if [ "$NEEDS_UPDATE" -eq 1 ]; then
      log "更新 ~/.zshrc 的 plugins=(...) 行（剔除 apt 包名, 它们走 source 加载）"
      sed -i.bak -E "s|^plugins=\([^)]*\)|plugins=(${WANT_PLUGINS[*]})|" "$ZSHRC"
      ok "plugins 已设为：${WANT_PLUGINS[*]}（备份在 ~/.zshrc.bak）"
    else
      ok "plugins=() 已是目标值"
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

  # apt 装的 zsh-syntax-highlighting / zsh-autosuggestions 不是 omz plugin 结构,
  # 直接 source 它们的入口文件 — 这是让功能真正工作的唯一机制。
  for srcline in \
    "source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    "source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
    if ! grep -Fq "$srcline" "$ZSHRC" 2>/dev/null; then
      f="${srcline#source }"
      [ -f "$f" ] && echo "$srcline" >> "$ZSHRC"
    fi
  done

  # 含 "/" 的是自定义主题 (如 powerlevel10k/powerlevel10k), 需要先 clone 到
  # ~/.oh-my-zsh/custom/themes/<repo>/。已知 mapping: powerlevel10k → romkatv/powerlevel10k
  case "$ZSH_THEME_NAME" in
    powerlevel10k/*)
      P10K_DIR="$USER_HOME/.oh-my-zsh/custom/themes/powerlevel10k"
      if [ -d "$P10K_DIR/.git" ]; then
        ok "powerlevel10k 已存在 ($P10K_DIR)"
      else
        log "克隆 powerlevel10k → $P10K_DIR"
        if [ "$(id -un)" = "$USER_NAME" ]; then
          git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
        else
          sudo -u "$USER_NAME" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$P10K_DIR"
        fi
        ok "powerlevel10k 克隆完成"
      fi
      ;;
  esac

  # 设 ZSH_THEME
  case "$ZSH_THEME_NAME" in
    */*) THEME_FILE="$USER_HOME/.oh-my-zsh/custom/themes/${ZSH_THEME_NAME}.zsh-theme" ;;
    *)   THEME_FILE="$USER_HOME/.oh-my-zsh/themes/${ZSH_THEME_NAME}.zsh-theme" ;;
  esac
  if [ ! -f "$THEME_FILE" ]; then
    warn "主题 '$ZSH_THEME_NAME' 在 $THEME_FILE 找不到"
    warn "继续设置, 但 zsh 启动时可能报错。检查拼写或自行下载主题文件。"
  fi

  if grep -qE '^ZSH_THEME=' "$ZSHRC"; then
    CUR_THEME="$(grep -m1 -E '^ZSH_THEME=' "$ZSHRC" | sed -E 's/^ZSH_THEME="?([^"]*)"?.*/\1/')"
    if [ "$CUR_THEME" = "$ZSH_THEME_NAME" ]; then
      ok "ZSH_THEME 已是 $ZSH_THEME_NAME"
    else
      sed -i.bak -E "s|^ZSH_THEME=.*|ZSH_THEME=\"$ZSH_THEME_NAME\"|" "$ZSHRC"
      ok "ZSH_THEME: $CUR_THEME → $ZSH_THEME_NAME"
    fi
  else
    {
      echo
      echo "# Added by server-bootstrap 02b-zsh"
      echo "ZSH_THEME=\"$ZSH_THEME_NAME\""
    } >> "$ZSHRC"
    ok "ZSH_THEME 已追加 = $ZSH_THEME_NAME"
  fi

  case "$ZSH_THEME_NAME" in
    powerlevel10k/*)
      log "提示: powerlevel10k 推荐你*本地终端*装 MesloLGS NF (Nerd Font) 才能完整显示 icon"
      log "      下载: https://github.com/romkatv/powerlevel10k/blob/master/font.md"
      log "      首次进交互 zsh 会跳出 'p10k configure' 向导, 选风格即可"
      ;;
    agnoster)
      log "提示: agnoster 主题用 Powerline 字符, 本地终端需装 Powerline 兼容字体"
      log "      (MesloLGS NF / Hack Nerd Font 都行)"
      ;;
  esac
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
