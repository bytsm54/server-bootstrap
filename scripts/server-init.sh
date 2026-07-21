#!/usr/bin/env bash
# server-init.sh — 仅初始化服务器，不安装 AI 工具或项目配置

set -euo pipefail

log() { printf '\033[1;34m[server-init]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: server-init.sh [options]

  --hostname <name>                    主机名（默认不修改）
  --timezone <zone>                    时区（默认 Asia/Shanghai）
  --install-zsh yes|no                 安装 zsh（默认 yes）
  --zsh-theme <theme>                  zsh 主题
  --node-version <lts-or-version>      Node.js 版本（默认 lts）
  --npm-registry official|china        npm registry（默认 official）
  --install-bun yes|no                 安装 Bun（默认 no）
  --git-name <name>                    Git user.name（必填）
  --git-email <email>                  Git user.email（必填）
  --harden-ssh yes|no                  SSH 加固（默认 yes）
  --ssh-port <port>                    SSH 新端口（默认 22022）
  --ssh-allow-users <users>            SSH AllowUsers，逗号分隔
  --ssh-permit-root yes|no             允许 root 登录（默认 no）
  --ssh-password-auth yes|no           允许密码登录（默认 no）
  --ssh-rollback-minutes <minutes>     SSH 回滚窗口（默认 5）
  --enable-fail2ban yes|no             启用 fail2ban（默认 yes）
  -h, --help                           显示帮助

环境变量 REPO_DIR 可覆盖仓库根目录。
EOF
}

valid_yes_no() {
  case "$1" in
    yes|no) return 0 ;;
    *) return 1 ;;
  esac
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] &&
    [ "$1" -ge 1024 ] &&
    [ "$1" -le 65535 ] &&
    [ "$1" -ne 22 ]
}

valid_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]
}

valid_node_version() {
  [ "$1" = "lts" ] || [[ "$1" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]]
}

valid_hostname() {
  [ -z "$1" ] && return 0
  [ "${#1}" -le 63 ] || return 1
  [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

valid_timezone() {
  [ -n "$1" ] || return 1
  case "/$1/" in
    */./*|*/../*) return 1 ;;
  esac
  [[ "$1" =~ ^[a-zA-Z0-9._+-]+(/[a-zA-Z0-9._+-]+)*$ ]] &&
    [ -f "/usr/share/zoneinfo/$1" ]
}

valid_user_list() {
  local remaining="$1"
  local user
  [ -n "$remaining" ] || return 1
  while :; do
    case "$remaining" in
      *,*)
        user="${remaining%%,*}"
        remaining="${remaining#*,}"
        [ -n "$remaining" ] || return 1
        ;;
      *) user="$remaining"; remaining="" ;;
    esac
    [[ "$user" =~ ^[^[:space:],]+$ ]] || return 1
    [ -n "$remaining" ] || break
  done
}

require_value() {
  if [ "$#" -lt 2 ]; then
    err "$1 需要一个值"
    exit 2
  fi
}

prompt_value() {
  local label="$1"
  local current="$2"
  local answer
  if [ -n "$current" ]; then
    printf '%s [%s]: ' "$label" "$current"
  else
    printf '%s: ' "$label"
  fi
  if ! read -r answer; then
    err "无法读取输入：$label"
    exit 2
  fi
  PROMPT_RESULT="${answer:-$current}"
}

run_phase() {
  local label="$1"
  shift
  log "$label"
  "$@" || {
    err "$label 失败，停止初始化"
    return 1
  }
}

validate_config() {
  valid_hostname "$HOSTNAME_VALUE" || { err "--hostname 格式不正确"; return 2; }
  valid_timezone "$TIMEZONE" || { err "--timezone 在 /usr/share/zoneinfo 中不存在"; return 2; }
  valid_node_version "$NODE_VERSION" || {
    err "--node-version 必须是 lts 或 1-3 段数字版本（可选 v 前缀）"
    return 2
  }
  valid_yes_no "$INSTALL_ZSH" || { err "--install-zsh 必须是 yes 或 no"; return 2; }
  if { [ "$ZSH_THEME_SET" -eq 1 ] || [ "$INSTALL_ZSH" = "yes" ]; } &&
     [ -z "$ZSH_THEME" ]; then
    err "--zsh-theme 不能为空"
    return 2
  fi
  valid_yes_no "$INSTALL_BUN" || { err "--install-bun 必须是 yes 或 no"; return 2; }
  valid_yes_no "$HARDEN_SSH" || { err "--harden-ssh 必须是 yes 或 no"; return 2; }
  valid_yes_no "$SSH_PERMIT_ROOT" || { err "--ssh-permit-root 必须是 yes 或 no"; return 2; }
  valid_yes_no "$SSH_PASSWORD_AUTH" || { err "--ssh-password-auth 必须是 yes 或 no"; return 2; }
  valid_yes_no "$ENABLE_FAIL2BAN" || { err "--enable-fail2ban 必须是 yes 或 no"; return 2; }

  case "$NPM_REGISTRY" in
    official|china) ;;
    *) err "--npm-registry 必须是 official 或 china"; return 2 ;;
  esac

  if [ "$HARDEN_SSH" = "yes" ] || [ "$SSH_PORT_SET" -eq 1 ]; then
    valid_port "$SSH_PORT" || {
      err "--ssh-port 必须是 1024-65535 且不能为 22"
      return 2
    }
  fi
  if [ "$HARDEN_SSH" = "yes" ] || [ "$SSH_ROLLBACK_MINUTES_SET" -eq 1 ]; then
    valid_positive_int "$SSH_ROLLBACK_MINUTES" || {
      err "--ssh-rollback-minutes 必须是正整数"
      return 2
    }
  fi
  if [ "$SSH_ALLOW_USERS_SET" -eq 1 ] ||
     { [ "$HARDEN_SSH" = "yes" ] && [ -n "$SSH_ALLOW_USERS" ]; }; then
    valid_user_list "$SSH_ALLOW_USERS" || {
      err "--ssh-allow-users 必须是非空的逗号分隔用户列表"
      return 2
    }
  fi

  if [ -n "$GIT_EMAIL" ]; then
    case "$GIT_EMAIL" in
      *@*.*) ;;
      *) err "--git-email 格式不正确"; return 2 ;;
    esac
  fi
}

HOSTNAME_VALUE=""
TIMEZONE="Asia/Shanghai"
INSTALL_ZSH="yes"
ZSH_THEME="powerlevel10k/powerlevel10k"
NODE_VERSION="lts"
NPM_REGISTRY="official"
INSTALL_BUN="no"
GIT_NAME=""
GIT_EMAIL=""
HARDEN_SSH="yes"
SSH_PORT="22022"
SSH_ALLOW_USERS=""
SSH_PERMIT_ROOT="no"
SSH_PASSWORD_AUTH="no"
SSH_ROLLBACK_MINUTES="5"
ENABLE_FAIL2BAN="yes"

HOSTNAME_SET=0
TIMEZONE_SET=0
INSTALL_ZSH_SET=0
ZSH_THEME_SET=0
NODE_VERSION_SET=0
NPM_REGISTRY_SET=0
INSTALL_BUN_SET=0
GIT_NAME_SET=0
GIT_EMAIL_SET=0
HARDEN_SSH_SET=0
SSH_PORT_SET=0
SSH_ALLOW_USERS_SET=0
SSH_PERMIT_ROOT_SET=0
SSH_PASSWORD_AUTH_SET=0
SSH_ROLLBACK_MINUTES_SET=0
ENABLE_FAIL2BAN_SET=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname)
      require_value "$@"; HOSTNAME_VALUE="$2"; HOSTNAME_SET=1; shift 2 ;;
    --timezone)
      require_value "$@"; TIMEZONE="$2"; TIMEZONE_SET=1; shift 2 ;;
    --install-zsh)
      require_value "$@"; INSTALL_ZSH="$2"; INSTALL_ZSH_SET=1; shift 2 ;;
    --zsh-theme)
      require_value "$@"; ZSH_THEME="$2"; ZSH_THEME_SET=1; shift 2 ;;
    --node-version)
      require_value "$@"; NODE_VERSION="$2"; NODE_VERSION_SET=1; shift 2 ;;
    --npm-registry)
      require_value "$@"; NPM_REGISTRY="$2"; NPM_REGISTRY_SET=1; shift 2 ;;
    --install-bun)
      require_value "$@"; INSTALL_BUN="$2"; INSTALL_BUN_SET=1; shift 2 ;;
    --git-name)
      require_value "$@"; GIT_NAME="$2"; GIT_NAME_SET=1; shift 2 ;;
    --git-email)
      require_value "$@"; GIT_EMAIL="$2"; GIT_EMAIL_SET=1; shift 2 ;;
    --harden-ssh)
      require_value "$@"; HARDEN_SSH="$2"; HARDEN_SSH_SET=1; shift 2 ;;
    --ssh-port)
      require_value "$@"; SSH_PORT="$2"; SSH_PORT_SET=1; shift 2 ;;
    --ssh-allow-users)
      require_value "$@"; SSH_ALLOW_USERS="$2"; SSH_ALLOW_USERS_SET=1; shift 2 ;;
    --ssh-permit-root)
      require_value "$@"; SSH_PERMIT_ROOT="$2"; SSH_PERMIT_ROOT_SET=1; shift 2 ;;
    --ssh-password-auth)
      require_value "$@"; SSH_PASSWORD_AUTH="$2"; SSH_PASSWORD_AUTH_SET=1; shift 2 ;;
    --ssh-rollback-minutes)
      require_value "$@"; SSH_ROLLBACK_MINUTES="$2"; SSH_ROLLBACK_MINUTES_SET=1; shift 2 ;;
    --enable-fail2ban)
      require_value "$@"; ENABLE_FAIL2BAN="$2"; ENABLE_FAIL2BAN_SET=1; shift 2 ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      err "未知参数: $1"
      exit 2 ;;
  esac
done

validate_config || exit $?

INTERACTIVE=0
case "${SERVER_INIT_INTERACTIVE:-}" in
  yes) INTERACTIVE=1 ;;
  no) INTERACTIVE=0 ;;
  "") [ -t 0 ] && INTERACTIVE=1 ;;
  *) err "SERVER_INIT_INTERACTIVE 必须是 yes 或 no"; exit 2 ;;
esac

if [ "$INTERACTIVE" -eq 1 ]; then
  if [ "$HOSTNAME_SET" -eq 0 ]; then
    prompt_value "主机名（留空不修改）" "$HOSTNAME_VALUE"
    HOSTNAME_VALUE="$PROMPT_RESULT"
  fi
  if [ "$TIMEZONE_SET" -eq 0 ]; then
    prompt_value "时区" "$TIMEZONE"
    TIMEZONE="$PROMPT_RESULT"
  fi
  if [ "$INSTALL_ZSH_SET" -eq 0 ]; then
    prompt_value "安装 zsh (yes/no)" "$INSTALL_ZSH"
    INSTALL_ZSH="$PROMPT_RESULT"
  fi
  if [ "$INSTALL_ZSH" = "yes" ] && [ "$ZSH_THEME_SET" -eq 0 ]; then
    prompt_value "zsh 主题" "$ZSH_THEME"
    ZSH_THEME="$PROMPT_RESULT"
  fi
  if [ "$NODE_VERSION_SET" -eq 0 ]; then
    prompt_value "Node.js 版本" "$NODE_VERSION"
    NODE_VERSION="$PROMPT_RESULT"
  fi
  if [ "$NPM_REGISTRY_SET" -eq 0 ]; then
    prompt_value "npm registry (official/china)" "$NPM_REGISTRY"
    NPM_REGISTRY="$PROMPT_RESULT"
  fi
  if [ "$INSTALL_BUN_SET" -eq 0 ]; then
    prompt_value "安装 Bun (yes/no)" "$INSTALL_BUN"
    INSTALL_BUN="$PROMPT_RESULT"
  fi
  if [ "$GIT_NAME_SET" -eq 0 ]; then
    prompt_value "Git user.name" "$GIT_NAME"
    GIT_NAME="$PROMPT_RESULT"
  fi
  if [ "$GIT_EMAIL_SET" -eq 0 ]; then
    prompt_value "Git user.email" "$GIT_EMAIL"
    GIT_EMAIL="$PROMPT_RESULT"
  fi
  if [ "$HARDEN_SSH_SET" -eq 0 ]; then
    prompt_value "SSH 加固 (yes/no)" "$HARDEN_SSH"
    HARDEN_SSH="$PROMPT_RESULT"
  fi
  if [ "$HARDEN_SSH" = "yes" ]; then
    if [ "$SSH_PORT_SET" -eq 0 ]; then
      prompt_value "SSH 新端口" "$SSH_PORT"
      SSH_PORT="$PROMPT_RESULT"
    fi
    if [ "$SSH_ALLOW_USERS_SET" -eq 0 ]; then
      CURRENT_USER="$(whoami 2>/dev/null || true)"
      if [ -z "$CURRENT_USER" ]; then
        err "无法通过 whoami 确定 SSH allow-users 默认值"
        exit 2
      fi
      prompt_value "SSH 允许用户（逗号分隔）" "$CURRENT_USER"
      SSH_ALLOW_USERS="$PROMPT_RESULT"
    fi
    if [ "$SSH_PERMIT_ROOT_SET" -eq 0 ]; then
      prompt_value "允许 SSH root 登录 (yes/no)" "$SSH_PERMIT_ROOT"
      SSH_PERMIT_ROOT="$PROMPT_RESULT"
    fi
    if [ "$SSH_PASSWORD_AUTH_SET" -eq 0 ]; then
      prompt_value "允许 SSH 密码登录 (yes/no)" "$SSH_PASSWORD_AUTH"
      SSH_PASSWORD_AUTH="$PROMPT_RESULT"
    fi
    if [ "$SSH_ROLLBACK_MINUTES_SET" -eq 0 ]; then
      prompt_value "SSH 自动回滚分钟数" "$SSH_ROLLBACK_MINUTES"
      SSH_ROLLBACK_MINUTES="$PROMPT_RESULT"
    fi
  fi
  if [ "$ENABLE_FAIL2BAN_SET" -eq 0 ]; then
    prompt_value "启用 fail2ban (yes/no)" "$ENABLE_FAIL2BAN"
    ENABLE_FAIL2BAN="$PROMPT_RESULT"
  fi
elif [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  err "非交互模式缺少必填 Git 身份：--git-name 和 --git-email"
  exit 2
fi

validate_config || exit $?

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  err "Git user.name 和 user.email 必须提供"
  exit 2
fi

if [ "$HARDEN_SSH" = "yes" ]; then
  if [ -z "$SSH_ALLOW_USERS" ]; then
    CURRENT_USER="$(whoami 2>/dev/null || true)"
    if [ -z "$CURRENT_USER" ]; then
      err "无法通过 whoami 确定 SSH allow-users 默认值"
      exit 2
    fi
    SSH_ALLOW_USERS="$CURRENT_USER"
  fi
fi

if [ "$INTERACTIVE" -ne 1 ]; then
  err "服务器初始化必须交互确认；请在终端中运行后确认配置"
  exit 2
fi

cat <<EOF

================ 服务器初始化配置 ================
hostname:              ${HOSTNAME_VALUE:-不修改}
timezone:              $TIMEZONE
install zsh:           $INSTALL_ZSH
zsh theme:             $ZSH_THEME
Node.js:               $NODE_VERSION
npm registry:          $NPM_REGISTRY
install Bun:           $INSTALL_BUN
Git name:              $GIT_NAME
Git email:             $GIT_EMAIL
harden SSH:            $HARDEN_SSH
SSH port:              $SSH_PORT
SSH allow users:       ${SSH_ALLOW_USERS:-不适用}
SSH permit root:       $SSH_PERMIT_ROOT
SSH password auth:     $SSH_PASSWORD_AUTH
SSH rollback minutes:  $SSH_ROLLBACK_MINUTES
enable fail2ban:       $ENABLE_FAIL2BAN
==================================================
EOF

printf '确认执行？输入 y / yes / 是 / 确认: '
if ! read -r OVERALL_CONFIRMATION; then
  err "无法读取整体确认"
  exit 2
fi
case "$OVERALL_CONFIRMATION" in
  y|yes|是|确认) ;;
  *) ok "已取消，未执行任何 phase"; exit 0 ;;
esac

REPO_ROOT="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPTS_DIR="$REPO_ROOT/scripts"
REQUIRED_PHASES=(
  01-preflight.sh
  02-base-deps.sh
  02a-system.sh
  02b-zsh.sh
  03-node.sh
  05-git-identity.sh
  08-ssh-harden.sh
  09-fail2ban.sh
  verify-server.sh
)
for phase in "${REQUIRED_PHASES[@]}"; do
  if [ ! -f "$SCRIPTS_DIR/$phase" ]; then
    err "缺少必需 phase: $SCRIPTS_DIR/$phase"
    exit 1
  fi
done

run_phase "环境预检" bash "$SCRIPTS_DIR/01-preflight.sh"
run_phase "基础依赖" bash "$SCRIPTS_DIR/02-base-deps.sh"

SYSTEM_ARGS=()
[ -z "$HOSTNAME_VALUE" ] || SYSTEM_ARGS+=(--hostname "$HOSTNAME_VALUE")
[ -z "$TIMEZONE" ] || SYSTEM_ARGS+=(--timezone "$TIMEZONE")
if [ "${#SYSTEM_ARGS[@]}" -gt 0 ]; then
  run_phase "系统配置" bash "$SCRIPTS_DIR/02a-system.sh" "${SYSTEM_ARGS[@]}"
fi

if [ "$INSTALL_ZSH" = "yes" ]; then
  run_phase "zsh 配置" bash "$SCRIPTS_DIR/02b-zsh.sh" --theme "$ZSH_THEME"
fi

run_phase "Node.js 配置" bash "$SCRIPTS_DIR/03-node.sh" \
  --node-version "$NODE_VERSION" \
  --npm-registry "$NPM_REGISTRY" \
  --install-bun "$INSTALL_BUN"

run_phase "Git 身份" bash "$SCRIPTS_DIR/05-git-identity.sh" \
  --name "$GIT_NAME" \
  --email "$GIT_EMAIL"

FAIL2BAN_SSH_PORT=22
if [ "$HARDEN_SSH" = "yes" ]; then
  cat <<EOF

================ SSH 加固安全确认 ================
新端口:          $SSH_PORT
允许用户:        $SSH_ALLOW_USERS
允许 root:       $SSH_PERMIT_ROOT
允许密码登录:    $SSH_PASSWORD_AUTH
自动回滚窗口:    $SSH_ROLLBACK_MINUTES 分钟

请先在云防火墙 / 安全组放行新端口，并保持当前会话开启。
EOF
  printf '准备完成后输入“已准备”，其他输入将跳过 SSH 加固: '
  SSH_GATE=""
  read -r SSH_GATE || true
  if [ "$SSH_GATE" = "已准备" ]; then
    run_phase "SSH 加固" bash "$SCRIPTS_DIR/08-ssh-harden.sh" apply \
      --port "$SSH_PORT" \
      --allow-users "$SSH_ALLOW_USERS" \
      --permit-root "$SSH_PERMIT_ROOT" \
      --password-auth "$SSH_PASSWORD_AUTH" \
      --rollback-after-minutes "$SSH_ROLLBACK_MINUTES"

    printf '请从第二个终端测试新端口；成功后输入“成功”，否则将立即回滚: '
    SSH_RESULT=""
    SSH_TIMEOUT_SECONDS=$((10#$SSH_ROLLBACK_MINUTES * 60))
    if read -r -t "$SSH_TIMEOUT_SECONDS" SSH_RESULT && [ "$SSH_RESULT" = "成功" ]; then
      run_phase "确认 SSH 加固" bash "$SCRIPTS_DIR/08-ssh-harden.sh" confirm
      FAIL2BAN_SSH_PORT="$SSH_PORT"
    else
      run_phase "回滚 SSH 加固" bash "$SCRIPTS_DIR/08-ssh-harden.sh" rollback
      FAIL2BAN_SSH_PORT=22
    fi
  else
    ok "已跳过 SSH 加固"
  fi
fi

if [ "$ENABLE_FAIL2BAN" = "yes" ]; then
  run_phase "fail2ban 配置" bash "$SCRIPTS_DIR/09-fail2ban.sh" --ssh-port "$FAIL2BAN_SSH_PORT"
fi

run_phase "服务器验证" bash "$SCRIPTS_DIR/verify-server.sh"
ok "纯服务器初始化完成"
