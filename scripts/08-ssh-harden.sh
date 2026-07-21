#!/usr/bin/env bash
# 08-ssh-harden.sh — SSH 加固（高风险）
#
# 三种模式（必须明确传一个）：
#
#   apply    --port <N> --allow-users <u1[,u2,...]>
#            [--permit-root no|yes]                    (默认 no)
#            [--password-auth no|yes]                   (默认 no)
#            [--rollback-after-minutes <N>]             (默认 5)
#            [--no-deadman]                             (跳过自动回滚, 不推荐)
#     备份 + 调度/记录 deadman + 写新配置 + sshd -t + reload
#
#   confirm
#     新端口已验证可登录, 取消 deadman 自动回滚
#
#   rollback [--auto]
#     立即回滚到当前 deadman 记录对应的备份（旧记录回退到最近备份）
#     --auto: 由 deadman 触发, 仅用于日志区分
#
# 安全约束（脚本内强制）：
#   - 修改 sshd_config 前 tar 备份整个 /etc/ssh
#   - 禁用 password 前必须确认 allow_users 都有 authorized_keys
#   - 永远 systemctl reload sshd（不是 restart）, 以保活当前 SSH 会话
#   - 修改通过 drop-in /etc/ssh/sshd_config.d/00-server-bootstrap.conf
#     （除非系统 sshd_config 没有 Include 指令, 则直接 patch 主文件）
#
# Agent 调用约束（见 SKILL.md phase 08 dialog）：
#   apply 之前必须先把警告对话念给用户, 等用户"已准备"才能调
#   apply 之后必须让用户在另一终端验证
#   验证 OK → confirm；失败或超时 → 自动 rollback

set -euo pipefail

log()  { printf '\033[1;34m[08-ssh-harden]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

SSHD_MAIN=/etc/ssh/sshd_config
SSHD_DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN_NAME=00-server-bootstrap.conf
BACKUP_DIR=/var/backups/sshd-bootstrap
DEADMAN_FILE=/var/run/sshd-bootstrap-deadman.atjob

# Ubuntu 22.04+ / Debian 12+ 用 systemd socket activation 持有 listening fd,
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
  echo "/etc/systemd/system/${unit}.d/override.conf"
}

# --- sudo 包装
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "本 phase 改 sshd 配置, 需要 sudo / root, 但都没有"
    exit 1
  fi
  SUDO=(sudo)
else
  SUDO=()
fi

deadman_record_exists() {
  "${SUDO[@]}" test -s "$DEADMAN_FILE"
}

read_deadman_job_id() {
  "${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | head -1
}

read_deadman_backup_file() {
  "${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | sed -n '2p'
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
  local temp_file="${DEADMAN_FILE}.tmp.$$"

  if ! printf '%s\n%s\n' "$job_id" "$backup_file" |
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

  if ! "${SUDO[@]}" rm -f "$SSHD_DROPIN_DIR/$DROPIN_NAME"; then
    err "无法移除 SSH drop-in"
    return 1
  fi
  if ! "${SUDO[@]}" tar xzf "$backup_file" -C /; then
    err "无法恢复 SSH 备份 $backup_file"
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
  if ! "${SUDO[@]}" systemctl reload ssh 2>/dev/null &&
     ! "${SUDO[@]}" systemctl reload sshd 2>/dev/null; then
    err "reload sshd 失败"
    return 1
  fi
}

# 必须在 SUDO 定义之后才能用 systemctl 探测
SOCKET_UNIT="$(detect_socket_unit || true)"

# --- 解析模式
MODE="${1:-}"; shift || true
case "$MODE" in
  apply|confirm|rollback) ;;
  -h|--help|"")
    sed -n '2,40p' "$0"
    exit 0 ;;
  *) err "未知模式: $MODE"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# CONFIRM
# ---------------------------------------------------------------------------
if [ "$MODE" = "confirm" ]; then
  if [ ! -s "$DEADMAN_FILE" ] && ! "${SUDO[@]}" test -s "$DEADMAN_FILE"; then
    warn "没有找到 deadman 任务记录（可能已经 confirm 过了, 或 apply 没成功）"
    exit 0
  fi
  JOB_ID="$("${SUDO[@]}" cat "$DEADMAN_FILE" 2>/dev/null | head -1)"
  if [ -n "$JOB_ID" ]; then
    log "取消 at 任务 $JOB_ID"
    cancel_deadman_job "$JOB_ID" || exit 1
  fi
  "${SUDO[@]}" rm -f "$DEADMAN_FILE"
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

  RECORDED_JOB=""
  RECORDED_BACKUP=""
  if deadman_record_exists; then
    RECORDED_JOB="$(read_deadman_job_id)"
    RECORDED_BACKUP="$(read_deadman_backup_file)"
  fi

  if [ "$AUTO" -eq 1 ] && [ -n "$REQUESTED_BACKUP" ] &&
     [ "$RECORDED_BACKUP" != "$REQUESTED_BACKUP" ]; then
    warn "忽略 stale deadman：matching backup 已不再拥有当前记录"
    exit 0
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

  restore_ssh_backup "$ROLLBACK_BACKUP" || exit 1

  if [ "$AUTO" -eq 0 ] && [ -n "$RECORDED_JOB" ]; then
    cancel_deadman_job "$RECORDED_JOB" || exit 1
    "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  elif [ "$AUTO" -eq 1 ] && [ -n "$RECORDED_BACKUP" ] &&
       [ "$RECORDED_BACKUP" = "$ROLLBACK_BACKUP" ]; then
    "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  fi

  ok "已回滚到 $ROLLBACK_BACKUP 并 reload sshd"
  exit 0
fi

# ---------------------------------------------------------------------------
# APPLY
# ---------------------------------------------------------------------------
PORT=""
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
    --no-deadman)               USE_DEADMAN=0; shift ;;
    *) err "apply: 未知参数 $1"; exit 2 ;;
  esac
done

# --- 参数校验
if [ -z "$PORT" ] || [ -z "$ALLOW_USERS" ]; then
  err "apply 必须提供 --port 和 --allow-users"
  exit 2
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
  err "--port 必须在 1024-65535（你给了 $PORT）"
  exit 2
fi
if [ "$PORT" = "22" ]; then
  err "拒绝把端口设为 22（这违背了改端口的目的）"
  exit 2
fi
case "$PERMIT_ROOT"   in yes|no) ;; *) err "--permit-root 必须 yes 或 no";   exit 2 ;; esac
case "$PASSWORD_AUTH" in yes|no) ;; *) err "--password-auth 必须 yes 或 no"; exit 2 ;; esac
if ! [[ "$ROLLBACK_MIN" =~ ^[0-9]+$ ]] || [ "$ROLLBACK_MIN" -lt 1 ]; then
  err "--rollback-after-minutes 必须正整数"
  exit 2
fi

# --- 安全检查：禁用密码登录 → 确认 allow_users 都有 authorized_keys
if [ "$PASSWORD_AUTH" = "no" ]; then
  IFS=',' read -ra USERS <<< "$ALLOW_USERS"
  for u in "${USERS[@]}"; do
    u_trim="$(echo "$u" | xargs)"
    [ -z "$u_trim" ] && continue
    if [ "$u_trim" = "root" ]; then
      AK="/root/.ssh/authorized_keys"
    else
      uhome="$(getent passwd "$u_trim" | cut -d: -f6)"
      [ -z "$uhome" ] && { err "用户 $u_trim 不存在"; exit 1; }
      AK="$uhome/.ssh/authorized_keys"
    fi
    if ! "${SUDO[@]}" test -s "$AK"; then
      err "FATAL: 用户 $u_trim 的 $AK 不存在或为空"
      err "禁用密码登录会立即把 $u_trim 锁出去, 拒绝执行"
      err "解决：先把 ssh public key 写到 $AK, 或加 --password-auth yes"
      exit 1
    fi
    ok "$u_trim 的 authorized_keys 已存在 ($AK)"
  done
fi

# --- deadman 前置：at 是否可用
if [ "$USE_DEADMAN" -eq 1 ]; then
  if ! command -v at >/dev/null 2>&1; then
    err "需要 at(1) 做 deadman 自动回滚, 但未安装"
    err "解决：先跑 02-base-deps.sh（已含 at）, 或 sudo apt-get install -y at"
    err "或者用 --no-deadman 强制跳过（不推荐）"
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
  if [ -z "$PRIOR_JOB_ID" ]; then
    err "已有 deadman 记录但缺少 job ID；拒绝覆盖"
    exit 1
  fi
  log "取消上一次未确认的 at 任务 $PRIOR_JOB_ID"
  cancel_deadman_job "$PRIOR_JOB_ID" || exit 1
  "${SUDO[@]}" rm -f "$DEADMAN_FILE"
fi

# --- 备份
TS="$(date +%Y%m%d-%H%M%S)"
"${SUDO[@]}" mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/sshd-$TS-$$.tar.gz"
log "备份 /etc/ssh（+socket override 如有）→ $BACKUP_FILE"
BACKUP_PATHS=(etc/ssh/sshd_config)
"${SUDO[@]}" test -d /etc/ssh/sshd_config.d         && BACKUP_PATHS+=(etc/ssh/sshd_config.d)
"${SUDO[@]}" test -d /etc/systemd/system/ssh.socket.d  && BACKUP_PATHS+=(etc/systemd/system/ssh.socket.d)
"${SUDO[@]}" test -d /etc/systemd/system/sshd.socket.d && BACKUP_PATHS+=(etc/systemd/system/sshd.socket.d)
"${SUDO[@]}" tar czf "$BACKUP_FILE" -C / "${BACKUP_PATHS[@]}"
ok "备份完成"

# --- 在任何 live SSH mutation 之前调度并持久化 matching deadman
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEADMAN_ARMED=0
if [ "$USE_DEADMAN" -eq 1 ]; then
  printf -v ROLLBACK_SCRIPT_Q '%q' "$REPO_ROOT/scripts/08-ssh-harden.sh"
  printf -v BACKUP_FILE_Q '%q' "$BACKUP_FILE"
  ROLLBACK_CMD="bash $ROLLBACK_SCRIPT_Q rollback --auto --backup-file $BACKUP_FILE_Q"
  log "调度 deadman: $ROLLBACK_MIN 分钟后自动回滚（除非你跑 confirm）"
  if ! AT_OUT="$(echo "$ROLLBACK_CMD" | "${SUDO[@]}" at "now + $ROLLBACK_MIN minutes" 2>&1)"; then
    err "at 调度失败：$AT_OUT"
    exit 1
  fi
  JOB_ID="$(echo "$AT_OUT" | sed -nE 's/^job ([0-9]+).*/\1/p' | head -1)"
  if [ -z "$JOB_ID" ]; then
    err "at 调度结果无法解析 job ID：$AT_OUT"
    exit 1
  fi
  if ! write_deadman_record "$JOB_ID" "$BACKUP_FILE"; then
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
      warn "恢复已完成，但 deadman 取消未确认；保留记录供自动路径再次恢复"
    fi
  fi
  exit "$status"
}

# From this point onward, every failure must restore the backup paired above.
trap 'apply_failure_handler $?' ERR

# --- 检测主 sshd_config 是否有 Include 指令
USE_DROPIN=0
if "${SUDO[@]}" grep -qE '^[[:space:]]*Include[[:space:]]+.*sshd_config\.d/\*\.conf' "$SSHD_MAIN" 2>/dev/null; then
  USE_DROPIN=1
fi

# --- 写新配置
ALLOW_USERS_SPACED="$(echo "$ALLOW_USERS" | tr ',' ' ')"
NEW_CONF=$(cat <<EOF
# Managed by server-bootstrap 08-ssh-harden — generated $TS
# 想回滚：bash 08-ssh-harden.sh rollback
Port $PORT
PermitRootLogin $PERMIT_ROOT
PasswordAuthentication $PASSWORD_AUTH
KbdInteractiveAuthentication $PASSWORD_AUTH
ChallengeResponseAuthentication $PASSWORD_AUTH
PubkeyAuthentication yes
AllowUsers $ALLOW_USERS_SPACED
X11Forwarding no
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
)

if [ "$USE_DROPIN" -eq 1 ]; then
  TARGET="$SSHD_DROPIN_DIR/$DROPIN_NAME"
  log "写 drop-in：$TARGET"
  "${SUDO[@]}" mkdir -p "$SSHD_DROPIN_DIR"
  echo "$NEW_CONF" | "${SUDO[@]}" tee "$TARGET" >/dev/null
  "${SUDO[@]}" chmod 644 "$TARGET"
else
  log "无 Include 指令, 把配置追加到 $SSHD_MAIN 末尾（已先备份）"
  echo "$NEW_CONF" | "${SUDO[@]}" tee -a "$SSHD_MAIN" >/dev/null
fi

# --- 校验
log "sshd -t 校验"
if ! "${SUDO[@]}" sshd -t; then
  err "sshd -t 失败！立即回滚"
  apply_failure_handler 1
fi
ok "sshd -t 通过"

# --- reload（不 restart, 保活当前会话）
log "systemctl reload sshd（保活当前会话）"
"${SUDO[@]}" systemctl reload ssh 2>/dev/null || \
  "${SUDO[@]}" systemctl reload sshd 2>/dev/null || \
  { err "reload 失败"; apply_failure_handler 1; }
ok "sshd reloaded"

# --- socket activation 处理
# Ubuntu 22.04+ / Debian 12+: ssh.socket 持有 listening fd, sshd_config 的 Port 被旁路
# 必须改 socket 单元的 ListenStream, 然后 restart ssh.socket（不影响已建立的 SSH 会话）
SOCKET_OVERRIDE=""
if [ -n "$SOCKET_UNIT" ]; then
  SOCKET_OVERRIDE="$(socket_override_path "$SOCKET_UNIT")"
  log "检测到 socket activation ($SOCKET_UNIT), 写 ListenStream override → $SOCKET_OVERRIDE"
  "${SUDO[@]}" mkdir -p "$(dirname "$SOCKET_OVERRIDE")"
  # ListenStream= 空行清空原值, 否则 systemd 追加而非替换。
  # 必须显式写 0.0.0.0:$PORT + [::]:$PORT 双栈监听 — 上游 ssh.socket 的 [Socket]
  # 段带了 BindIPv6Only=ipv6-only, 单写 "ListenStream=$PORT" 会被强制 IPv6-only,
  # IPv4 客户端连不进, ss 只看得到 tcp6 :::$PORT。这跟上游的 IPv4+IPv6 双栈写法对齐。
  cat <<EOF | "${SUDO[@]}" tee "$SOCKET_OVERRIDE" >/dev/null
# Managed by server-bootstrap 08-ssh-harden — generated $TS
[Socket]
ListenStream=
ListenStream=0.0.0.0:$PORT
ListenStream=[::]:$PORT
EOF
  "${SUDO[@]}" chmod 644 "$SOCKET_OVERRIDE"
  "${SUDO[@]}" systemctl daemon-reload
  log "重启 $SOCKET_UNIT（仅切换 listening fd, 已建立的 SSH 会话不受影响）"
  if ! "${SUDO[@]}" systemctl restart "$SOCKET_UNIT"; then
    err "重启 $SOCKET_UNIT 失败, 立即回滚"
    apply_failure_handler 1
  fi
  ok "$SOCKET_UNIT 已切换到端口 $PORT"
else
  log "未检测到 socket activation, 走传统 sshd 直接 listen 模式"
fi

# --- 实际端口监听验证（不能只信 sshd -t 和 reload）
log "验证端口 $PORT 实际监听"
PORT_LISTEN_OK=0
for _ in 1 2 3 4 5; do
  if "${SUDO[@]}" ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT\$"; then
    PORT_LISTEN_OK=1
    break
  fi
  sleep 1
done
if [ "$PORT_LISTEN_OK" -ne 1 ]; then
  err "端口 $PORT 没有任何进程监听！立即内联回滚"
  err "可能原因：socket activation 切换失败 / 端口已被占用 / sshd 启动失败"
  apply_failure_handler 1
fi
ok "端口 $PORT 已确认监听"

trap - ERR

cat <<EOF

\033[1;33m============================================================\033[0m
\033[1;33m 下一步（重要 — 请仔细做）：\033[0m
\033[1;33m============================================================\033[0m
 1) 不要关闭你当前这个 SSH 会话！
 2) 在另一台机器（或当前机器的另一个终端）尝试登录新端口：
       ssh -p $PORT <user>@<this-host>
 3) 如果新端口能登上来：
       bash $REPO_ROOT/scripts/08-ssh-harden.sh confirm
    （取消 deadman, 视为加固成功）
 4) 如果登不上来：什么都别做。$ROLLBACK_MIN 分钟后会自动回滚。
    或者立即手动回滚：
       bash $REPO_ROOT/scripts/08-ssh-harden.sh rollback

\033[1;31m⚠ 云防火墙 / 安全组提醒：\033[0m
   如果你这台机器在 AWS/阿里云/腾讯云/GCP 等云平台, 请确保
   入站规则已经放行端口 $PORT, 否则 sshd 接受连接但包到不了。

EOF
