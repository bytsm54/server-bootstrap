#!/usr/bin/env bash
# Shared defaults and validation. Sourcing this file does not change the host.

init_privilege() {
  SUDO=(env)
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null || { echo '需要 sudo 或 root' >&2; return 1; }
    SUDO=(sudo)
    [ "${1:-}" != noninteractive ] || SUDO+=( -n )
  fi
}

valid_yes_no() { [[ "$1" = yes || "$1" = no ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_positive_int() { [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]]; }
valid_hostname() {
  [ -z "$1" ] && return 0
  [ "${#1}" -le 63 ] && [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}
valid_user_list() { [[ "$1" =~ ^[a-z_][a-z0-9_-]*([$])?(,[a-z_][a-z0-9_-]*([$])?)*$ ]]; }
valid_timezone() {
  [ -z "$1" ] && return 0
  case "/$1/" in */./*|*/../*) return 1 ;; esac
  [[ "$1" =~ ^[a-zA-Z0-9._+-]+(/[a-zA-Z0-9._+-]+)*$ ]] && [ -f "/usr/share/zoneinfo/$1" ]
}

config_defaults() {
  HOSTNAME_VALUE=''; TIMEZONE=Asia/Shanghai
  INSTALL_ZSH=no; ZSH_THEME=robbyrussell
  INSTALL_NODE=no; NODE_VERSION=lts; NPM_REGISTRY=china; INSTALL_BUN=no
  GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
  GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
  HARDEN_SSH=yes; SSH_PORT=''; SSH_ALLOW_USERS="${SUDO_USER:-$(id -un)}"
  SSH_PERMIT_ROOT=no; SSH_PASSWORD_AUTH=no; SSH_ROLLBACK_MINUTES=5
  ENABLE_FAIL2BAN=yes; PROJECT_REPO=''; PROJECT_DIR=''; ENV_KEYS=''
  ASSUME_YES=no; SHOW_CONFIG=no; STAGE=all
  SET_OPTIONS=' '
}

parse_config() {
  while [ "$#" -gt 0 ]; do
    local option="$1" target=''
    case "$option" in
      --hostname) target=HOSTNAME_VALUE ;; --timezone) target=TIMEZONE ;;
      --install-zsh) target=INSTALL_ZSH ;; --zsh-theme) target=ZSH_THEME ;;
      --install-node) target=INSTALL_NODE ;; --node-version) target=NODE_VERSION ;;
      --npm-registry) target=NPM_REGISTRY ;; --install-bun) target=INSTALL_BUN ;;
      --git-name) target=GIT_NAME ;; --git-email) target=GIT_EMAIL ;;
      --harden-ssh) target=HARDEN_SSH ;; --ssh-port) target=SSH_PORT ;;
      --ssh-allow-users) target=SSH_ALLOW_USERS ;; --ssh-permit-root) target=SSH_PERMIT_ROOT ;;
      --ssh-password-auth) target=SSH_PASSWORD_AUTH ;; --ssh-rollback-minutes) target=SSH_ROLLBACK_MINUTES ;;
      --enable-fail2ban) target=ENABLE_FAIL2BAN ;; --repo) target=PROJECT_REPO ;;
      --project-dir) target=PROJECT_DIR ;; --env-keys) target=ENV_KEYS ;; --stage) target=STAGE ;;
      --yes) ASSUME_YES=yes; shift; continue ;;
      --show-config) SHOW_CONFIG=yes; shift; continue ;;
      *) echo "未知参数: $option" >&2; return 2 ;;
    esac
    [ "$#" -ge 2 ] || { echo "$option 需要一个值" >&2; return 2; }
    printf -v "$target" '%s' "$2"
    SET_OPTIONS="$SET_OPTIONS$option "
    shift 2
  done
}

validate_config() {
  local variable
  for variable in INSTALL_ZSH INSTALL_NODE INSTALL_BUN HARDEN_SSH SSH_PERMIT_ROOT SSH_PASSWORD_AUTH ENABLE_FAIL2BAN; do
    valid_yes_no "${!variable}" || { echo "$variable 必须为 yes/no" >&2; return 2; }
  done
  valid_hostname "$HOSTNAME_VALUE" || { echo 'hostname 格式无效' >&2; return 2; }
  valid_timezone "$TIMEZONE" || { echo 'timezone 不存在或格式无效' >&2; return 2; }
  [ -z "$SSH_PORT" ] || valid_port "$SSH_PORT" || { echo 'ssh-port 必须为 1–65535 或留空' >&2; return 2; }
  valid_user_list "$SSH_ALLOW_USERS" || { echo 'ssh-allow-users 必须为实际用户名，以逗号分隔' >&2; return 2; }
  valid_positive_int "$SSH_ROLLBACK_MINUTES" || { echo 'ssh-rollback-minutes 必须为正整数' >&2; return 2; }
  [[ "$NODE_VERSION" = lts || "$NODE_VERSION" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]] || { echo 'node-version 无效' >&2; return 2; }
  [[ "$NPM_REGISTRY" = china || "$NPM_REGISTRY" = official ]] || { echo 'npm-registry 必须为 china/official' >&2; return 2; }
  [[ "$ZSH_THEME" =~ ^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)?$ ]] || { echo 'zsh-theme 无效' >&2; return 2; }
  case "$STAGE" in all|prepare|verify) ;; *) echo 'stage 必须为 all/prepare/verify' >&2; return 2 ;; esac
  [ -z "$GIT_EMAIL" ] || [[ "$GIT_EMAIL" = *@*.* ]] || { echo 'git-email 无效' >&2; return 2; }
  case "$PROJECT_REPO" in -*) echo 'repo 不能以 - 开头' >&2; return 2 ;; esac
}

print_config() {
  local variable
  for variable in HOSTNAME_VALUE TIMEZONE INSTALL_ZSH ZSH_THEME INSTALL_NODE NODE_VERSION NPM_REGISTRY INSTALL_BUN GIT_NAME GIT_EMAIL HARDEN_SSH SSH_PORT SSH_ALLOW_USERS SSH_PERMIT_ROOT SSH_PASSWORD_AUTH SSH_ROLLBACK_MINUTES ENABLE_FAIL2BAN PROJECT_REPO PROJECT_DIR ENV_KEYS; do
    printf '%s=%q\n' "$variable" "${!variable}"
  done
}

root_account_guidance() {
  cat >&2 <<'EOF'
关闭 root SSH 前需要一个可登录的普通管理账号。
请先由 root 执行 adduser <name> 和 usermod -aG sudo <name>，
为该账号配置自己的 SSH 公钥，并从第二个终端验证密钥登录和 sudo。
随后用该账号重新运行；或显式传入已经验证的 --ssh-allow-users <name>。
EOF
}
