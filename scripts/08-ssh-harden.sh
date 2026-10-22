#!/usr/bin/env bash
# 08-ssh-harden.sh — SSH 加固（高风险）
#
# 四种模式（必须明确传一个）：
#
#   apply    [--port <N>] --allow-users <u1[,u2,...]>
#            --port 默认 22022；显式传空字符串保持当前端口
#            [--permit-root no|yes]                    (默认 no)
#            [--password-auth no|yes]                   (默认 no)
#            [--rollback-after-minutes <N>]             (默认 5)
#     备份 + 调度/记录 deadman + 写新配置 + sshd -t + reload
#
#   confirm
#     新端口已验证可登录, 取消 deadman 自动回滚
#
#   rollback [--auto]
#     立即回滚到当前 deadman 记录对应的备份（旧记录回退到最近备份）
#     --auto: 由 deadman 触发, 仅用于日志区分
#
#   deadline
#     输出当前 armed deadman 的 absolute deadline（epoch 秒）
#
# 安全约束（脚本内强制）：
#   - 修改 sshd_config 前 tar 备份整个 /etc/ssh
#   - 禁用 password 前必须确认 allow_users 都有 authorized_keys
#   - 普通服务 reload；socket 重启前校验 KillMode=process，保留当前会话
#   - 修改通过 drop-in /etc/ssh/sshd_config.d/00-server-bootstrap.conf
#     （在主文件全局作用域首部加载；保留其他设置）
#
# Agent 调用约束（见 SKILL.md phase 08 dialog）：
#   apply 前展示目标配置，并确认允许账号已验证公钥登录
#   apply 之后必须让用户在另一终端验证
#   验证 OK → confirm；失败或超时 → 自动 rollback

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/ssh-state.sh"

case "${1:-}" in
  -h|--help|'')
    echo 'Usage: 08-ssh-harden.sh apply [--port N] --allow-users user,... | confirm | rollback | deadline'
    exit 0 ;;
esac

ORIGINAL_ARGS=("$@")

log()  { printf '\033[1;34m[08-ssh-harden]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

SSHD_MAIN=/etc/ssh/sshd_config
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN_NAME=00-server-bootstrap.conf
BACKUP_DIR=/var/backups/sshd-bootstrap
DEADMAN_FILE=/var/run/sshd-bootstrap-deadman.atjob
LOCK_FILE="${SSH_HARDEN_LOCK_FILE:-/var/run/sshd-bootstrap.lock}"

# Ubuntu 的 systemd socket activation 可以持有 listening fd,
# sshd_config 的 Port 指令会被旁路。此函数返回当前 active 的 socket 单元名。
detect_socket_unit() {
  for unit in ssh.socket sshd.socket; do
    if "${SUDO[@]}" systemctl is-active --quiet "$unit" 2>/dev/null; then
      echo "$unit"
      return 0
    fi
  done
  return 1
}

socket_override_path() {
  local unit="$1"
  echo "/etc/systemd/system/${unit}.d/99-server-bootstrap.conf"
}

# --- sudo 包装
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "本 phase 改 sshd 配置, 需要 sudo / root, 但都没有"
    exit 1
  fi
  SUDO=(sudo)
else
  SUDO=(env)
fi

# Elevate once so the process can open the host-local lock file. The marker may
# skip only the elevation re-exec; every process still acquires the lock itself.
if [ "$(id -u)" -ne 0 ] && [ "${SSH_HARDEN_ELEVATED:-0}" != 1 ]; then
  exec "${SUDO[@]}" /usr/bin/env \
    SSH_HARDEN_ELEVATED=1 \
    SSH_HARDEN_LOCK_FILE="$LOCK_FILE" \
    SSH_CONNECTION="${SSH_CONNECTION:-}" \
    bash "$0" "${ORIGINAL_ARGS[@]}"
fi
if ! command -v flock >/dev/null 2>&1; then
  err "需要 flock(1) 串行化 SSH 状态转换, 但未安装（请先跑 02-base-deps.sh）"
  exit 1
fi
if ! exec 9>"$LOCK_FILE"; then
  err "无法打开 SSH 状态锁 $LOCK_FILE"
  exit 1
fi
flock -x 9

deadman_record_exists() {
  "${SUDO[@]}" test -s "$DEADMAN_FILE"
}

read_deadman_job_id() {
  "${SUDO[@]}" sed -n '1p' "$DEADMAN_FILE" 2>/dev/null
}

read_deadman_backup_file() {
  "${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | sed -n '2p'
}

read_deadman_deadline() {
  "${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | sed -n '3p'
}

read_deadman_state() {
  "${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | sed -n '4p'
}

record_state_is_armed() {
  [ "$1" = armed ] || [ -z "$1" ]
}

cancel_deadman_job() {
  local job_id="$1"
  if ! "${SUDO[@]}" atrm "$job_id" 2>/dev/null; then
    err "无法确认 at 任务 $job_id 已取消；保留 deadman 记录"
    return 1
  fi
}

write_deadman_record() {
  local job_id="$1"
  local backup_file="$2"
  local deadline="$3"
  local state="$4"
  local temp_file="${DEADMAN_FILE}.tmp.$$"

  if ! printf '%s\n%s\n%s\n%s\n' "$job_id" "$backup_file" "$deadline" "$state" |
       "${SUDO[@]}" tee "$temp_file" >/dev/null; then
    "${SUDO[@]}" rm -f "$temp_file" 2>/dev/null || true
    return 1
  fi
  "${SUDO[@]}" chmod 600 "$temp_file" || {
    "${SUDO[@]}" rm -f "$temp_file" 2>/dev/null || true
    return 1
  }
  "${SUDO[@]}" mv "$temp_file" "$DEADMAN_FILE" || {
    "${SUDO[@]}" rm -f "$temp_file" 2>/dev/null || true
    return 1
  }
}

latest_backup_file() {
  if "${SUDO[@]}" test -d "$BACKUP_DIR"; then
    "${SUDO[@]}" sh -c "ls -1t '$BACKUP_DIR'/sshd-*.tar.gz 2>/dev/null | head -1" || true
  fi
}

restore_ssh_backup() {
  local backup_file="$1"
  local socket_override=""
  local relative_path=""

  # A failed socket restart can leave the unit inactive. Use the backed-up
  # identity rather than detecting only currently active sockets during recovery.
  if "${SUDO[@]}" test -f "$backup_file.socket-unit"; then
    SOCKET_UNIT="$("${SUDO[@]}" cat "$backup_file.socket-unit")"
  fi

  if ! "${SUDO[@]}" rm -f "$SSHD_DROPIN_DIR/$DROPIN_NAME"; then
    err "无法移除 SSH drop-in"
    return 1
  fi
  if ! "${SUDO[@]}" tar xzf "$backup_file" -C /; then
    err "无法恢复 SSH 备份 $backup_file"
    return 1
  fi

  if ! "${SUDO[@]}" sshd -t; then
    err '恢复的 SSH 配置未通过语法检查；保留当前会话'
    return 1
  fi

  if [ -n "$SOCKET_UNIT" ]; then
    socket_override="$(socket_override_path "$SOCKET_UNIT")"
    relative_path="${socket_override#/}"
    if "${SUDO[@]}" test -f "$socket_override" &&
       ! "${SUDO[@]}" tar tzf "$backup_file" 2>/dev/null | grep -qx "$relative_path"; then
      log "删除 apply 时新建的 $SOCKET_UNIT override"
      if ! "${SUDO[@]}" rm -f "$socket_override"; then
        err "无法移除 $SOCKET_UNIT override"
        return 1
      fi
    fi
    log "daemon-reload + 重启 $SOCKET_UNIT, 让恢复后的配置生效"
    if ! "${SUDO[@]}" systemctl daemon-reload; then
      err "systemd daemon-reload 失败"
      return 1
    fi
    if ! "${SUDO[@]}" systemctl restart "$SOCKET_UNIT"; then
      err "重启 $SOCKET_UNIT 失败, 端口可能未恢复"
      return 1
    fi
  fi

  if ! "${SUDO[@]}" sshd -t 2>/dev/null; then
    err "回滚后 sshd -t 仍失败, 可能配置已损坏, 不要 reload sshd！"
    err "请人工 ssh 进去（旧端口的会话还活着）查 $SSHD_MAIN"
    return 1
  fi
  if ! ssh_reload_daemon; then
    err "reload sshd 失败"
    return 1
  fi
  local expected_ports actual_ports attempt
  if ! expected_ports="$("${SUDO[@]}" cat "$backup_file.ports")"; then
    err '备份缺少原监听端口，无法确认回滚结果'; return 1
  fi
  for attempt in 1 2 3 4 5; do
    actual_ports="$(ssh_actual_ports 2>/dev/null || true)"
    if [ -n "$expected_ports" ] && [ "$actual_ports" = "$expected_ports" ]; then
      "${SUDO[@]}" rm -f /var/lib/server-bootstrap/ssh-confirmed
      if "${SUDO[@]}" test -f "$backup_file.confirmed"; then
        "${SUDO[@]}" cp "$backup_file.confirmed" /var/lib/server-bootstrap/ssh-confirmed || return 1
      fi
      return 0
    fi
    sleep 1
  done
  err '回滚后实际 SSH 监听不符，保留恢复记录'; return 1
}

# 必须在 SUDO 定义之后才能用 systemctl 探测
SOCKET_UNIT="$(detect_socket_unit || true)"

# --- 解析模式
MODE="${1:-}"; shift || true
case "$MODE" in
  apply|confirm|rollback|deadline) ;;
  -h|--help|"")
    sed -n '2,40p' "$0"
    exit 0 ;;
  *) err "未知模式: $MODE"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# DEADLINE (server-init reads the already-running automatic clock)
# ---------------------------------------------------------------------------
if [ "$MODE" = deadline ]; then
  if ! deadman_record_exists; then
    err "没有 armed deadman 记录"
    exit 1
  fi
  RECORDED_BACKUP="$(read_deadman_backup_file)"
  RECORDED_DEADLINE="$(read_deadman_deadline)"
  RECORDED_STATE="$(read_deadman_state)"
  if [ -z "$RECORDED_BACKUP" ] ||
     ! [[ "$RECORDED_DEADLINE" =~ ^[0-9]+$ ]] ||
     ! record_state_is_armed "$RECORDED_STATE"; then
    err "deadman 记录没有可用的 absolute deadline"
    exit 1
  fi
  printf '%s\n' "$RECORDED_DEADLINE"
  exit 0
fi

# ---------------------------------------------------------------------------
# CONFIRM
# ---------------------------------------------------------------------------
if [ "$MODE" = "confirm" ]; then
  if [ ! -s "$DEADMAN_FILE" ] && ! "${SUDO[@]}" test -s "$DEADMAN_FILE"; then
    err "没有找到 armed deadman 记录；无法确认 SSH 仍在新配置"
    exit 1
  fi
  JOB_ID="$("${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | head -1)"
  CONFIRM_BACKUP="$(read_deadman_backup_file)"
  CONFIRM_STATE="$(read_deadman_state)"
  if [ -n "$CONFIRM_BACKUP" ] && ! record_state_is_armed "$CONFIRM_STATE"; then
    err "deadman 记录已不再由 apply 持有；拒绝确认"
    exit 1
  fi
  CONFIRM_DEADLINE="$(read_deadman_deadline)"
  if ! [[ "$CONFIRM_DEADLINE" =~ ^[0-9]+$ ]] || [ "$(date +%s)" -ge "$CONFIRM_DEADLINE" ]; then
    err '确认窗口已结束，请等待或执行 rollback'; exit 1
  fi
  "${SUDO[@]}" sshd -t
  CONFIRM_PORTS="$("${SUDO[@]}" awk 'tolower($1)=="port" {print $2}' "$SSHD_DROPIN_DIR/$DROPIN_NAME" | sort -nu | paste -sd, -)"
  [ -n "$CONFIRM_PORTS" ] && [ "$(ssh_actual_ports)" = "$CONFIRM_PORTS" ] || {
    err '确认时 SSH 实际监听已经变化，保留自动回滚'; exit 1;
  }
  "${SUDO[@]}" mkdir -p /var/lib/server-bootstrap
  "${SUDO[@]}" sha256sum "$SSHD_MAIN" "$SSHD_DROPIN_DIR/$DROPIN_NAME" | "${SUDO[@]}" tee /var/lib/server-bootstrap/ssh-confirmed.tmp >/dev/null
  if [ -n "$JOB_ID" ]; then
    log "取消 at 任务 $JOB_ID"
    cancel_deadman_job "$JOB_ID" || exit 1
  fi
  "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  "${SUDO[@]}" mv /var/lib/server-bootstrap/ssh-confirmed.tmp /var/lib/server-bootstrap/ssh-confirmed
  ok "已确认成功, deadman 已取消"
  exit 0
fi

# ---------------------------------------------------------------------------
# ROLLBACK
# ---------------------------------------------------------------------------
if [ "$MODE" = "rollback" ]; then
  AUTO=0
  REQUESTED_BACKUP=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --auto) AUTO=1; shift ;;
      --backup-file)
        [ "$#" -ge 2 ] || { err "--backup-file 需要一个值"; exit 2; }
        REQUESTED_BACKUP="$2"
        shift 2
        ;;
      *) err "rollback: 未知参数 $1"; exit 2 ;;
    esac
  done

  RECORD_EXISTS=0
  RECORDED_JOB=""
  RECORDED_BACKUP=""
  RECORDED_DEADLINE=""
  RECORDED_STATE=""
  if deadman_record_exists; then
    RECORD_EXISTS=1
    RECORDED_JOB="$(read_deadman_job_id)"
    RECORDED_BACKUP="$(read_deadman_backup_file)"
    RECORDED_DEADLINE="$(read_deadman_deadline)"
    RECORDED_STATE="$(read_deadman_state)"
  fi

  if [ "$AUTO" -eq 1 ]; then
    if [ -z "$REQUESTED_BACKUP" ]; then
      if [ "$RECORD_EXISTS" -eq 0 ]; then
        warn "忽略 legacy deadman：当前没有记录"
        exit 0
      fi
      if [ -n "$RECORDED_BACKUP" ]; then
        warn "忽略 legacy deadman：当前记录属于 new-format job"
        exit 0
      fi
    else
      if [ "$RECORD_EXISTS" -eq 0 ] || [ "$RECORDED_BACKUP" != "$REQUESTED_BACKUP" ]; then
        warn "忽略 stale deadman：matching backup 已不再拥有当前记录"
        exit 0
      fi
      if [ "$RECORDED_STATE" = manual-restored ]; then
        warn "手动回滚已完成；自动任务不再重复 restore"
        "${SUDO[@]}" rm -f "$DEADMAN_FILE"
        exit 0
      fi
      if ! record_state_is_armed "$RECORDED_STATE"; then
        warn "忽略 deadman：记录状态不是 armed"
        exit 0
      fi
    fi
  fi

  ROLLBACK_BACKUP="$REQUESTED_BACKUP"
  [ -n "$ROLLBACK_BACKUP" ] || ROLLBACK_BACKUP="$RECORDED_BACKUP"
  [ -n "$ROLLBACK_BACKUP" ] || ROLLBACK_BACKUP="$(latest_backup_file)"
  if [ -z "$ROLLBACK_BACKUP" ]; then
    err "没有可用的备份, 无法回滚"
    exit 1
  fi

  if [ "$AUTO" -eq 1 ]; then
    warn "deadman 自动触发回滚（用户在窗口期内未 confirm）"
  else
    log "手动回滚到 $ROLLBACK_BACKUP"
  fi

  # Keep the scheduled recovery armed until both files and listeners recover.
  restore_ssh_backup "$ROLLBACK_BACKUP" || exit 1
  CANCEL_FAILED=0
  if [ "$AUTO" -eq 0 ] && [ -n "$RECORDED_JOB" ]; then
    if ! cancel_deadman_job "$RECORDED_JOB"; then CANCEL_FAILED=1; fi
  fi

  if [ "$AUTO" -eq 1 ]; then
    "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  elif [ "$CANCEL_FAILED" -eq 1 ]; then
    [ -n "$RECORDED_DEADLINE" ] || RECORDED_DEADLINE=0
    if ! write_deadman_record \
      "$RECORDED_JOB" "$ROLLBACK_BACKUP" "$RECORDED_DEADLINE" manual-restored; then
      err "手动回滚已完成，但无法写入 harmless ownership 状态"
    fi
    err "SSH 已恢复，但 at 任务取消未确认"
    exit 1
  elif [ "$RECORD_EXISTS" -eq 1 ]; then
    "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  fi

  ok "已回滚到 $ROLLBACK_BACKUP 并 reload sshd"
  exit 0
fi

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------
PORT="$DEFAULT_SSH_PORT"
ALLOW_USERS=""
PERMIT_ROOT="no"
PASSWORD_AUTH="no"
ROLLBACK_MIN=5
USE_DEADMAN=1

while [ $# -gt 0 ]; do
  case "$1" in
    --port)                     PORT="$2"; shift 2 ;;
    --allow-users)              ALLOW_USERS="$2"; shift 2 ;;
    --permit-root)              PERMIT_ROOT="$2"; shift 2 ;;
    --password-auth)            PASSWORD_AUTH="$2"; shift 2 ;;
    --rollback-after-minutes)   ROLLBACK_MIN="$2"; shift 2 ;;
    *) err "apply: 未知参数 $1"; exit 2 ;;
  esac
done

# Validate before touching live configuration.
valid_user_list "$ALLOW_USERS" || { err "--allow-users 必须为实际用户名，以逗号分隔"; exit 2; }
[ -z "$PORT" ] || valid_port "$PORT" || { err "--port 必须为 1–65535 或留空"; exit 2; }
valid_yes_no "$PERMIT_ROOT" && valid_yes_no "$PASSWORD_AUTH" || exit 2
valid_positive_int "$ROLLBACK_MIN" || exit 2
if [ "$PERMIT_ROOT" = no ] && [ "$ALLOW_USERS" = root ]; then root_account_guidance; exit 2; fi
ORIGINAL_PORTS="$(ssh_actual_ports)"
REQUESTED_PORT="$PORT"
if [ -n "$PORT" ]; then
  PORT="$((10#$PORT))"
  ssh_port_available "$PORT" || exit 1
  TARGET_PORTS="$PORT"
else
  TARGET_PORTS="$ORIGINAL_PORTS"
fi
SOCKET_ADDRESSES=''
LEGACY_SOCKET=''
if [ -n "$SOCKET_UNIT" ]; then
  SOCKET_ADDRESSES="$(ssh_socket_addresses "$SOCKET_UNIT")"
  legacy="/etc/systemd/system/${SOCKET_UNIT}.d/override.conf"
  if "${SUDO[@]}" test -f "$legacy" && "${SUDO[@]}" grep -q '^# Managed by server-bootstrap 08-ssh-harden' "$legacy" && "${SUDO[@]}" grep -q '^[[:space:]]*ListenStream[[:space:]]*=' "$legacy"; then
    [ ! -L "$legacy" ] || { err '旧 SSH socket 配置是软链，拒绝迁移'; exit 1; }
    LEGACY_SOCKET="$legacy"
  fi
  SERVICE_UNIT="${SOCKET_UNIT%.socket}.service"
  KILL_MODE="$("${SUDO[@]}" systemctl show "$SERVICE_UNIT" --property=KillMode --value)"
  [ "$KILL_MODE" = process ] || { err "$SERVICE_UNIT 的 KillMode 必须为 process 才能保留当前会话"; exit 1; }
  REQUIRES="$("${SUDO[@]}" systemctl show "$SERVICE_UNIT" --property=Requires --value)"
  case " $REQUIRES " in *" $SOCKET_UNIT "*) ;; *) err "$SERVICE_UNIT 缺少对 $SOCKET_UNIT 的 Requires 依赖"; exit 1 ;; esac
fi
IFS=',' read -r -a USERS <<< "$ALLOW_USERS"
CLIENT_ADDR="${SSH_CONNECTION:-}"
CLIENT_ADDR="${CLIENT_ADDR%% *}"
CLIENT_ADDR="${CLIENT_ADDR:-127.0.0.1}"
for user in "${USERS[@]}"; do
  user_home="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$user_home" ] || { err "用户不存在: $user"; exit 1; }
  if [ "$PASSWORD_AUTH" = no ]; then
    config="$(ssh_effective_config -C "user=$user,host=$CLIENT_ADDR,addr=$CLIENT_ADDR")"
    key_files="$(printf '%s\n' "$config" | awk '$1=="authorizedkeysfile" {$1=""; print}')"
    found_key=0
    for key_file in $key_files; do
      key_file="${key_file//%h/$user_home}"
      key_file="${key_file//%u/$user}"
      case "$key_file" in /*) ;; *) key_file="$user_home/$key_file" ;; esac
      if "${SUDO[@]}" test -s "$key_file"; then found_key=1; break; fi
    done
    [ "$found_key" -eq 1 ] || { err "未找到 $user 的 authorized_keys；请先配置并验证公钥登录"; exit 1; }
  fi
done

# --- deadman 前置：at 是否可用
if [ "$USE_DEADMAN" -eq 1 ]; then
  if ! command -v at >/dev/null 2>&1; then
    err "需要 at(1) 做 deadman 自动回滚, 但未安装"
    err "解决：先跑 02-base-deps.sh（已含 at）, 或 sudo apt-get install -y at"
    exit 1
  fi
  if ! "${SUDO[@]}" systemctl is-active --quiet atd 2>/dev/null \
       && ! "${SUDO[@]}" systemctl is-active --quiet at-daemon 2>/dev/null; then
    log "atd 未运行, 启动它"
    "${SUDO[@]}" systemctl enable --now atd 2>/dev/null || \
      "${SUDO[@]}" systemctl enable --now at-daemon 2>/dev/null || \
      { err "无法启动 atd, deadman 不可用"; exit 1; }
  fi
fi

# A previous apply owns the current record until its queued job is proven cancelled.
# Never overwrite that ownership with a new job while the old job may still execute.
if deadman_record_exists; then
  PRIOR_JOB_ID="$(read_deadman_job_id)"
  PRIOR_BACKUP="$(read_deadman_backup_file)"
  PRIOR_STATE="$(read_deadman_state)"
  if [ -z "$PRIOR_JOB_ID" ]; then
    err "已有 deadman 记录但缺少 job ID；拒绝覆盖"
    exit 1
  fi
  if [ -n "$PRIOR_BACKUP" ] && [ "$PRIOR_STATE" = manual-restore-failed ]; then
    err "上一次手动回滚尚未恢复成功；请先重试 rollback"
    exit 1
  elif [ -n "$PRIOR_BACKUP" ] && [ "$PRIOR_STATE" = manual-restored ]; then
    log "清理已完成手动回滚的 harmless ownership 记录"
    "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  else
    err "上一次 SSH 修改尚未确认，请先 confirm 或 rollback"
    exit 1
  fi
fi

# --- 备份
TS="$(date +%Y%m%d-%H%M%S)"
"${SUDO[@]}" mkdir -p "$BACKUP_DIR"
"${SUDO[@]}" chmod 700 "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/sshd-$TS-$$.tar.gz"
log "备份 /etc/ssh（+socket override 如有）→ $BACKUP_FILE"
BACKUP_PATHS=(etc/ssh/sshd_config)
"${SUDO[@]}" test -d /etc/ssh/sshd_config.d         && BACKUP_PATHS+=(etc/ssh/sshd_config.d)
"${SUDO[@]}" test -d /etc/systemd/system/ssh.socket.d  && BACKUP_PATHS+=(etc/systemd/system/ssh.socket.d)
"${SUDO[@]}" test -d /etc/systemd/system/sshd.socket.d && BACKUP_PATHS+=(etc/systemd/system/sshd.socket.d)
"${SUDO[@]}" tar czf "$BACKUP_FILE" -C / "${BACKUP_PATHS[@]}"
printf '%s\n' "$SOCKET_UNIT" | "${SUDO[@]}" tee "$BACKUP_FILE.socket-unit" >/dev/null
printf '%s\n' "$ORIGINAL_PORTS" | "${SUDO[@]}" tee "$BACKUP_FILE.ports" >/dev/null
if "${SUDO[@]}" test -f /var/lib/server-bootstrap/ssh-confirmed; then
  "${SUDO[@]}" cp /var/lib/server-bootstrap/ssh-confirmed "$BACKUP_FILE.confirmed"
fi
ok "备份完成"

# --- 在任何 live SSH mutation 之前调度并持久化 matching deadman
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEADMAN_ARMED=0
if [ "$USE_DEADMAN" -eq 1 ]; then
  ARMED_AT_EPOCH="$(date +%s)"
  if ! [[ "$ARMED_AT_EPOCH" =~ ^[0-9]+$ ]]; then
    err "无法读取当前 epoch 时间；SSH 尚未修改"
    exit 1
  fi
  AUTO_DEADLINE=$((ARMED_AT_EPOCH / 60 * 60 + 10#$ROLLBACK_MIN * 60))
  # Freeze the recovery implementation under a root-owned directory.
  RECOVERY_DIR="$BACKUP_FILE.recovery"
  "${SUDO[@]}" mkdir -p "$RECOVERY_DIR/lib"
  "${SUDO[@]}" install -m 700 "$0" "$RECOVERY_DIR/08-ssh-harden.sh"
  "${SUDO[@]}" install -m 600 "$SCRIPT_DIR/lib/common.sh" "$RECOVERY_DIR/lib/common.sh"
  "${SUDO[@]}" install -m 600 "$SCRIPT_DIR/lib/ssh-state.sh" "$RECOVERY_DIR/lib/ssh-state.sh"
  printf -v ROLLBACK_SCRIPT_Q '%q' "$RECOVERY_DIR/08-ssh-harden.sh"
  printf -v BACKUP_FILE_Q '%q' "$BACKUP_FILE"
  ROLLBACK_CMD="bash $ROLLBACK_SCRIPT_Q rollback --auto --backup-file $BACKUP_FILE_Q"
  log "调度 deadman: $ROLLBACK_MIN 分钟后自动回滚（除非你跑 confirm）"
  if ! AT_OUT="$(echo "$ROLLBACK_CMD" | "${SUDO[@]}" env LC_ALL=C at "now + $ROLLBACK_MIN minutes" 2>&1)"; then
    err "at 调度失败：$AT_OUT"
    exit 1
  fi
  JOB_ID="$(printf '%s\n' "$AT_OUT" | sed -nE 's/^job ([0-9]+).*/\1/p')"
  if [ -z "$JOB_ID" ]; then
    err "at 调度结果无法解析 job ID：$AT_OUT"
    exit 1
  fi
  if ! write_deadman_record "$JOB_ID" "$BACKUP_FILE" "$AUTO_DEADLINE" armed; then
    err "deadman 记录写入失败；SSH 尚未修改"
    cancel_deadman_job "$JOB_ID" || true
    exit 1
  fi
  DEADMAN_ARMED=1
  ok "deadman job=$JOB_ID, matching backup=$BACKUP_FILE"
fi

apply_failure_handler() {
  local status="${1:-1}"
  local restored=0

  trap - ERR
  set +e
  err "apply 失败；恢复 matching backup $BACKUP_FILE"
  if restore_ssh_backup "$BACKUP_FILE"; then
    restored=1
  else
    err "matching backup 恢复失败；保留 deadman 作为后备"
  fi

  if [ "$DEADMAN_ARMED" -eq 1 ] && [ "$restored" -eq 1 ]; then
    if cancel_deadman_job "$JOB_ID"; then
      "${SUDO[@]}" rm -f "$DEADMAN_FILE"
    else
      write_deadman_record "$JOB_ID" "$BACKUP_FILE" "$AUTO_DEADLINE" manual-restored ||
        warn "恢复已完成，但无法写入 harmless ownership 状态"
      warn "恢复已完成，但 deadman 取消未确认；后续自动任务将跳过 restore"
    fi
  fi
  exit "$status"
}

# From this point onward, every failure must restore the backup paired above.
trap 'apply_failure_handler $?' ERR
"${SUDO[@]}" rm -f /var/lib/server-bootstrap/ssh-confirmed

# Always load the managed file in global scope before other settings. Port and
# AllowUsers are additive; neutralize only global declarations in the main file.
# Conflicting declarations in other includes/Match blocks are detected below.
TARGET="$SSHD_DROPIN_DIR/$DROPIN_NAME"
TEMP_MAIN="$(mktemp)"
trap 'rm -f "$TEMP_MAIN"' EXIT
awk -v managed_include="Include $TARGET" '
  BEGIN {print managed_include}
  $0==managed_include {next}
  tolower($1)=="match" {in_match=1}
  !in_match && (tolower($1)=="port" || tolower($1)=="allowusers") {print "# server-bootstrap superseded: " $0; next}
  {print}
' "$SSHD_MAIN" > "$TEMP_MAIN"
"${SUDO[@]}" install -m 600 "$TEMP_MAIN" "$SSHD_MAIN.server-bootstrap.tmp"
"${SUDO[@]}" mv "$SSHD_MAIN.server-bootstrap.tmp" "$SSHD_MAIN"
"${SUDO[@]}" mkdir -p "$SSHD_DROPIN_DIR"
{
  echo '# Managed by server-bootstrap'
  printf '%s\n' "$TARGET_PORTS" | tr ',' '\n' | while read -r target_port; do printf 'Port %s\n' "$target_port"; done
  printf 'PermitRootLogin %s\nPasswordAuthentication %s\nKbdInteractiveAuthentication %s\n' "$PERMIT_ROOT" "$PASSWORD_AUTH" "$PASSWORD_AUTH"
  printf 'PubkeyAuthentication yes\nAllowUsers %s\nX11Forwarding no\nClientAliveInterval 60\nClientAliveCountMax 3\n' "${ALLOW_USERS//,/ }"
} | "${SUDO[@]}" tee "$TARGET.tmp" >/dev/null
"${SUDO[@]}" chmod 644 "$TARGET.tmp"
"${SUDO[@]}" mv "$TARGET.tmp" "$TARGET"
"${SUDO[@]}" sshd -t
for user in "${USERS[@]}"; do
  effective="$(ssh_effective_config -C "user=$user,host=$CLIENT_ADDR,addr=$CLIENT_ADDR")"
  for pair in "permitrootlogin:$PERMIT_ROOT" "passwordauthentication:$PASSWORD_AUTH" "kbdinteractiveauthentication:$PASSWORD_AUTH" 'pubkeyauthentication:yes' 'clientaliveinterval:60' 'clientalivecountmax:3'; do
    key="${pair%%:*}"; wanted="${pair#*:}"
    actual="$(printf '%s\n' "$effective" | awk -v k="$key" '$1==k {print $2}')"
    [ "$actual" = "$wanted" ] || { err "$user 的 $key 未生效（检查 Include/Match）"; apply_failure_handler 1; }
  done
  effective_ports="$(printf '%s\n' "$effective" | awk '$1=="port" {print $2}' | sort -nu | paste -sd, -)"
  [ "$effective_ports" = "$TARGET_PORTS" ] || { err 'Port 与目标不符（可能存在其他 Include 中的 Port）'; apply_failure_handler 1; }
  actual_users="$(printf '%s\n' "$effective" | awk '$1=="allowusers" {for(i=2;i<=NF;i++) print $i}' | sort -u | paste -sd, -)"
  expected_users="$(printf '%s\n' "$ALLOW_USERS" | tr ',' '\n' | sort -u | paste -sd, -)"
  [ "$actual_users" = "$expected_users" ] || { err 'AllowUsers 与目标不符'; apply_failure_handler 1; }
done

if [ "$PERMIT_ROOT" = no ]; then
  root_config="$(ssh_effective_config -C "user=root,host=$CLIENT_ADDR,addr=$CLIENT_ADDR")"
  [ "$(printf '%s\n' "$root_config" | awk '$1=="permitrootlogin" {print $2}')" = no ] || {
    err 'root 的 Match 配置覆盖了禁用策略'; apply_failure_handler 1;
  }
fi

# --- reload（不 restart, 保活当前会话）
log "systemctl reload sshd（保活当前会话）"
ssh_reload_daemon || { err "reload 失败"; apply_failure_handler 1; }
ok "sshd reloaded"

# Preserve bind addresses and families. A blank port leaves the socket untouched
# unless migrating a recognized legacy override, whose listeners are retained.
if [ -n "$SOCKET_UNIT" ] && { [ -n "$LEGACY_SOCKET" ] || { [ -n "$REQUESTED_PORT" ] && [ "$TARGET_PORTS" != "$ORIGINAL_PORTS" ]; }; }; then
  [ -n "$SOCKET_ADDRESSES" ] || { err '无法读取 SSH socket 监听地址'; apply_failure_handler 1; }
  SOCKET_OVERRIDE="$(socket_override_path "$SOCKET_UNIT")"
  "${SUDO[@]}" mkdir -p "$(dirname "$SOCKET_OVERRIDE")"
  {
    printf '# Managed by server-bootstrap\n[Socket]\nListenStream=\n'
    while read -r address; do
      [ -n "$address" ] || continue
      if [ -n "$REQUESTED_PORT" ]; then printf 'ListenStream=%s:%s\n' "${address%:*}" "$PORT"
      else printf 'ListenStream=%s\n' "$address"; fi
    done <<< "$SOCKET_ADDRESSES" | sort -u
  } | "${SUDO[@]}" tee "$SOCKET_OVERRIDE.tmp" >/dev/null
  "${SUDO[@]}" chmod 644 "$SOCKET_OVERRIDE.tmp"
  "${SUDO[@]}" mv "$SOCKET_OVERRIDE.tmp" "$SOCKET_OVERRIDE"
  if [ -n "$LEGACY_SOCKET" ]; then
    # The old file sorts after 99-*. Remove only its managed listen keys;
    # leave other user options/sections in place. The paired tar restores both.
    "${SUDO[@]}" cp -p "$LEGACY_SOCKET" "$LEGACY_SOCKET.server-bootstrap.tmp"
    "${SUDO[@]}" awk '
      /^[[:space:]]*\[/ {section=$0; gsub(/[[:space:]]/, "", section)}
      section=="[Socket]" && /^[[:space:]]*ListenStream[[:space:]]*=/ {next}
      {print}
    ' "$LEGACY_SOCKET" | "${SUDO[@]}" tee "$LEGACY_SOCKET.server-bootstrap.tmp" >/dev/null
    "${SUDO[@]}" mv "$LEGACY_SOCKET.server-bootstrap.tmp" "$LEGACY_SOCKET"
  fi
  "${SUDO[@]}" systemctl daemon-reload
  "${SUDO[@]}" systemctl restart "$SOCKET_UNIT"
fi
LISTEN_OK=0
for attempt in 1 2 3 4 5; do
  if [ "$(ssh_actual_ports 2>/dev/null || true)" = "$TARGET_PORTS" ]; then LISTEN_OK=1; break; fi
  sleep 1
done
[ "$LISTEN_OK" -eq 1 ] || { err 'SSH 实际监听与目标不符'; apply_failure_handler 1; }
trap - ERR

printf 'SSH 配置已应用，端口 %s，回滚窗口 %s 分钟。\n' "$TARGET_PORTS" "$ROLLBACK_MIN"
echo '保持当前会话，从第二个终端建立新的公钥连接。成功后运行 confirm；失败运行 rollback。'
