#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/python-env.sh"
THEME="$DEFAULT_ZSH_THEME"
DEFAULT_SHELL=yes
TARGET_USER="${SUDO_USER:-$(id -un)}"
while [ "$#" -gt 0 ]; do
  case "$1" in -h|--help) echo 'Usage: 02b-zsh.sh [--user username] [--theme theme] [--default-shell yes|no]'; exit 0 ;; esac
  [ "$#" -ge 2 ] || exit 2
  case "$1" in --user) TARGET_USER="$2" ;; --theme) THEME="$2" ;; --default-shell) DEFAULT_SHELL="$2" ;; *) exit 2 ;; esac
  shift 2
done
valid_yes_no "$DEFAULT_SHELL" || exit 2
[[ "$THEME" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)?$ ]] || exit 2
valid_user_list "$TARGET_USER" && [[ "$TARGET_USER" != *,* ]] || exit 2
USER_RECORD="$(getent passwd "$TARGET_USER")" || { echo "用户不存在: $TARGET_USER" >&2; exit 2; }
TARGET_HOME="$(printf '%s' "$USER_RECORD" | cut -d: -f6)"
init_privilege
MISSING=()
for package in zsh zsh-syntax-highlighting zsh-autosuggestions fonts-powerline; do
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || MISSING+=("$package")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${MISSING[@]}"
fi
# Re-enter as the selected account before creating user-owned files or cloning.
if [ "$(id -un)" != "$TARGET_USER" ]; then
  if [ "$(id -u)" = 0 ]; then
    RUN_AS=(runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER")
  else RUN_AS=(sudo -H -u "$TARGET_USER" env); fi
  "${RUN_AS[@]}" BOOTSTRAP_VENV="$TARGET_HOME/.local/share/server-bootstrap/helper-venv" \
    bash "$0" --user "$TARGET_USER" --theme "$THEME" --default-shell no
  # Keep the original caller's privilege; the selected account need not have sudo.
  if [ "$DEFAULT_SHELL" = yes ]; then "${SUDO[@]}" chsh -s "$(command -v zsh)" "$TARGET_USER"; fi
  exit 0
fi
export HOME="$TARGET_HOME"
if [ ! -d "$HOME/.oh-my-zsh" ]; then
  git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh"
fi
case "$THEME" in
  powerlevel10k/*)
    [ -d "$HOME/.oh-my-zsh/custom/themes/powerlevel10k" ] || \
      git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$HOME/.oh-my-zsh/custom/themes/powerlevel10k"
    ;;
esac
case "$THEME" in
  */*) THEME_PATH="$HOME/.oh-my-zsh/custom/themes/$THEME.zsh-theme" ;;
  *) THEME_PATH="$HOME/.oh-my-zsh/themes/$THEME.zsh-theme" ;;
esac
[ -f "$THEME_PATH" ] || { echo "主题不存在: $THEME" >&2; exit 1; }
ensure_python_env
RC="$HOME/.zshrc"
ANCHOR='^[ \t]*(source|\.)[ \t]+["\x27]?\$\{?ZSH\}?/oh-my-zsh\.sh'
if [ -f "$RC" ] && grep -q 'oh-my-zsh.sh' "$RC" && ! grep -q '^# BEGIN server-bootstrap:zsh-base$' "$RC"; then
  printf 'ZSH_THEME="%s"\ntypeset -Ua plugins\nplugins=(${plugins:#(zsh-autosuggestions|zsh-syntax-highlighting)})\nplugins+=(git sudo)\n' "$THEME" | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" zsh-theme --before "$ANCHOR"
else
  printf 'export ZSH="$HOME/.oh-my-zsh"\nZSH_THEME="%s"\ntypeset -Ua plugins\nplugins=(${plugins:#(zsh-autosuggestions|zsh-syntax-highlighting)})\nplugins+=(git sudo)\nsource "$ZSH/oh-my-zsh.sh"\n' "$THEME" | \
    "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" zsh-base
fi
cat <<'EOF' | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" zsh-extras
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
cat <<'EOF' | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" localbin-path
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$PATH:$HOME/.local/bin" ;; esac
EOF
zsh -n "$RC"
if [ "$DEFAULT_SHELL" = yes ]; then
  target="$(command -v zsh)"
  if [ "$(getent passwd "$(id -un)" | cut -d: -f7)" != "$target" ]; then
    "${SUDO[@]}" chsh -s "$target" "$(id -un)"
  fi
fi
echo "zsh + oh-my-zsh 配置完成，主题: ${THEME}；原有用户配置已保留"
[ "$DEFAULT_SHELL" != yes ] || echo '当前用户的默认 Shell 已设为 zsh；新登录会话生效'
