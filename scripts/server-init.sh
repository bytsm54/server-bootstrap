#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/ssh-state.sh"
usage() {
  cat <<'EOF'
Usage: server-init.sh [options]
  --hostname <name>                 留空保持现状
  --timezone <zone>                 默认 Asia/Shanghai；空字符串保持现状
  --install-node yes|no             默认 no
  --node-version <lts|version>      默认 lts
  --npm-registry china|official     默认 china
  --install-bun yes|no              默认 no（可独立安装）
  --install-zsh yes|no              默认 no
  --zsh-theme <theme>               默认 robbyrussell
  --git-name <name> --git-email <email>  默认复用已有全局身份
  --harden-ssh yes|no               默认 yes
  --ssh-port <1-65535>              默认 22022；空字符串保留当前端口
  --ssh-allow-users <user,...>       默认当前用户
  --ssh-permit-root yes|no          默认 no
  --ssh-password-auth yes|no        默认 no
  --ssh-rollback-minutes <minutes>  默认 5
  --enable-fail2ban yes|no          默认 yes
  --repo <url> --project-dir <path> --env-keys <key,...>  可选项目
  --show-config                    只展示归一化配置，不执行
  --yes                            已确认普通阶段配置；不会跳过 SSH 验证
  --stage all|prepare|verify        默认 all；prepare 不修改 SSH/fail2ban
  -h, --help
EOF
}
for argument in "$@"; do
  if [[ "$argument" = --help || "$argument" = -h ]]; then usage; exit 0; fi
done
config_defaults
parse_config "$@"
validate_config
if [ "$SHOW_CONFIG" = yes ]; then print_config; exit 0; fi

INPUT_FD=0
if [ ! -t 0 ] && [ "${SERVER_INIT_INTERACTIVE:-}" != yes ]; then
  if { exec 3<>/dev/tty; } 2>/dev/null; then INPUT_FD=3; else INPUT_FD=-1; fi
fi
read_answer() {
  [ "$INPUT_FD" -ge 0 ] || { echo '需要交互终端；Agent 可先使用 --stage prepare --yes，再按 Skill 执行 SSH 阶段' >&2; return 2; }
  read -r -u "$INPUT_FD" "$@"
}
prompt_option() {
  local option="$1" variable="$2" label="$3" answer
  case "$SET_OPTIONS" in *" $option "*) return ;; esac
  printf '%s [%s]: ' "$label" "${!variable}"
  read_answer answer || return 2
  [ -z "$answer" ] || printf -v "$variable" '%s' "$answer"
}
if [ "$ASSUME_YES" != yes ] && [ "$STAGE" != verify ]; then
  prompt_option --hostname HOSTNAME_VALUE '主机名（留空保持现状）'
  prompt_option --timezone TIMEZONE '时区（输入 keep 保持现状）'
  [ "$TIMEZONE" != keep ] || TIMEZONE=''
  prompt_option --install-node INSTALL_NODE '安装 Node (yes/no)'
  prompt_option --install-bun INSTALL_BUN '安装 Bun (yes/no)'
  prompt_option --install-zsh INSTALL_ZSH '安装 zsh (yes/no)'
  prompt_option --git-name GIT_NAME 'Git user.name'
  prompt_option --git-email GIT_EMAIL 'Git user.email'
  prompt_option --harden-ssh HARDEN_SSH 'SSH 加固 (yes/no)'
  if [ "$HARDEN_SSH" = yes ]; then
    prompt_option --ssh-port SSH_PORT 'SSH 端口（回车采用默认值，输入 keep 保持现状）'
    [ "$SSH_PORT" != keep ] || SSH_PORT=''
    prompt_option --ssh-allow-users SSH_ALLOW_USERS 'SSH 允许用户（逗号分隔）'
  fi
  prompt_option --enable-fail2ban ENABLE_FAIL2BAN '启用 fail2ban (yes/no)'
fi
validate_config
[ "$STAGE" = verify ] || { [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; } || { echo '缺少 Git 身份，请同时提供 --git-name 和 --git-email' >&2; exit 2; }
if [ "$STAGE" != verify ] && [ "$HARDEN_SSH" = yes ] && [ "$SSH_PERMIT_ROOT" = no ] && [ "$SSH_ALLOW_USERS" = root ]; then
  root_account_guidance; exit 2
fi
print_config
if [ "$ASSUME_YES" != yes ] && [ "$STAGE" != verify ]; then
  printf '确认执行以上配置？(yes/no): '
  read_answer answer
  case "$answer" in y|yes|是|确认) ;; *) echo '已取消'; exit 0 ;; esac
fi

PHASE_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}/scripts"
run_phase() { printf '\n[%s]\n' "$1"; bash "$PHASE_DIR/$1" "${@:2}"; }
verify_args=(--hostname "$HOSTNAME_VALUE" --timezone "$TIMEZONE" --install-node "$INSTALL_NODE"
  --node-version "$NODE_VERSION" --npm-registry "$NPM_REGISTRY" --install-bun "$INSTALL_BUN" --install-zsh "$INSTALL_ZSH" --zsh-theme "$ZSH_THEME"
  --git-name "$GIT_NAME" --git-email "$GIT_EMAIL" --harden-ssh "$HARDEN_SSH" --ssh-port "$SSH_PORT"
  --ssh-allow-users "$SSH_ALLOW_USERS" --ssh-permit-root "$SSH_PERMIT_ROOT" --ssh-password-auth "$SSH_PASSWORD_AUTH"
  --enable-fail2ban "$ENABLE_FAIL2BAN" --repo "$PROJECT_REPO" --project-dir "$PROJECT_DIR")
if [ "$STAGE" = verify ]; then run_phase verify-server.sh "${verify_args[@]}"; exit; fi
run_phase 01-preflight.sh
WITH_SSH=no
if [ "$HARDEN_SSH" = yes ] || [ "$ENABLE_FAIL2BAN" = yes ]; then WITH_SSH=yes; fi
run_phase 02-base-deps.sh --with-ssh "$WITH_SSH"
run_phase 02a-system.sh --hostname "$HOSTNAME_VALUE" --timezone "$TIMEZONE"
if [ "$INSTALL_ZSH" = yes ]; then run_phase 02b-zsh.sh --theme "$ZSH_THEME"; fi
if [ "$INSTALL_NODE" = yes ]; then
  run_phase 03-node.sh --node-version "$NODE_VERSION" --npm-registry "$NPM_REGISTRY" --install-bun no
fi
if [ "$INSTALL_BUN" = yes ]; then run_phase 03a-bun.sh; fi
run_phase 05-git-identity.sh --name "$GIT_NAME" --email "$GIT_EMAIL"
if [ -n "$PROJECT_REPO" ]; then
  bash "$SCRIPT_DIR/lib/with-env.sh" -- bash "$PHASE_DIR/06-project.sh" --repo "$PROJECT_REPO" --dir "$PROJECT_DIR" --env-keys "$ENV_KEYS"
fi
if [ "$STAGE" = prepare ]; then
  run_phase verify-server.sh "${verify_args[@]}" --harden-ssh no --enable-fail2ban no
  echo '普通阶段完成；SSH/fail2ban 尚未执行。按 Skill 完成后运行完整验收。'
  exit 0
fi

SSH_INCOMPLETE=0
if [ "$HARDEN_SSH" = yes ]; then
  init_privilege
  CURRENT_PORTS="$(ssh_actual_ports)"
  printf 'SSH 端口: %s → %s；允许用户: %s；密码登录: %s；root 登录: %s\n' \
    "$CURRENT_PORTS" "${SSH_PORT:-保持现状}" "$SSH_ALLOW_USERS" "$SSH_PASSWORD_AUTH" "$SSH_PERMIT_ROOT"
  echo '验证连接须禁用复用并强制公钥：ssh -S none -o ControlMaster=no -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -p <实际端口> <账号>@<服务器>'
  printf '请保持当前连接，先在另一终端验证允许账号的公钥登录和 sudo；若改端口，请放行目标端口。完成后输入“已准备”: '
  read_answer answer
  if [ "$answer" = 已准备 ]; then
    run_phase 08-ssh-harden.sh apply --port "$SSH_PORT" --allow-users "$SSH_ALLOW_USERS" \
      --permit-root "$SSH_PERMIT_ROOT" --password-auth "$SSH_PASSWORD_AUTH" --rollback-after-minutes "$SSH_ROLLBACK_MINUTES"
    deadline="$(bash "$PHASE_DIR/08-ssh-harden.sh" deadline)"
    [[ "$deadline" =~ ^[0-9]+$ ]] || { echo '无法读取 SSH 回滚截止时间' >&2; exit 1; }
    timeout=$((deadline - $(date +%s) - 30))
    printf '请用以上选项重新建立第二个 SSH 连接（目标端口），验证 sudo，成功后输入“成功”（剩余 %s 秒）: ' "$timeout"
    if [ "$timeout" -gt 0 ] && read_answer -t "$timeout" answer && [ "$answer" = 成功 ]; then
      run_phase 08-ssh-harden.sh confirm
    else
      run_phase 08-ssh-harden.sh rollback
      SSH_INCOMPLETE=1
    fi
  else
    echo 'SSH 加固未执行'; SSH_INCOMPLETE=1
  fi
fi
if [ "$ENABLE_FAIL2BAN" = yes ]; then run_phase 09-fail2ban.sh; fi
run_phase verify-server.sh "${verify_args[@]}" || exit 1
[ "$SSH_INCOMPLETE" -eq 0 ] || { echo 'SSH 请求未完成，初始化未全部通过' >&2; exit 1; }
echo '服务器初始化完成'
