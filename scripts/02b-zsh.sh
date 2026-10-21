#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/python-env.sh"
THEME=robbyrussell
DEFAULT_SHELL=yes
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || exit 2
  case "$1" in --theme) THEME="$2" ;; --default-shell) DEFAULT_SHELL="$2" ;; *) exit 2 ;; esac
  shift 2
done
valid_yes_no "$DEFAULT_SHELL" || exit 2
[[ "$THEME" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)?$ ]] || exit 2
init_privilege
MISSING=()
for package in zsh zsh-syntax-highlighting zsh-autosuggestions; do
  [ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" = 'install ok installed' ] || MISSING+=("$package")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  "${SUDO[@]}" apt-get update
  "${SUDO[@]}" apt-get install -y --no-install-recommends "${MISSING[@]}"
fi
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
ANCHOR='^[[:space:]]*(source|\.)[[:space:]]+["\x27]?\$\{?ZSH\}?/oh-my-zsh\.sh'
if [ -f "$RC" ] && grep -q 'oh-my-zsh.sh' "$RC" && ! grep -q '^# BEGIN server-bootstrap:zsh-base$' "$RC"; then
  printf 'ZSH_THEME="%s"\n' "$THEME" | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" zsh-theme --before "$ANCHOR"
else
  printf 'export ZSH="$HOME/.oh-my-zsh"\nZSH_THEME="%s"\ntypeset -Ua plugins\nplugins+=(git sudo)\nsource "$ZSH/oh-my-zsh.sh"\n' "$THEME" | \
    "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" zsh-base
fi
cat <<'EOF' | "$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/managed_file.py" "$RC" zsh-extras
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
EOF
zsh -n "$RC"
if [ "$DEFAULT_SHELL" = yes ]; then
  target="$(command -v zsh)"
  if [ "$(getent passwd "$(id -un)" | cut -d: -f7)" != "$target" ]; then
    "${SUDO[@]}" chsh -s "$target" "$(id -un)"
  fi
fi
echo 'zsh 配置完成；原有用户配置已保留'
