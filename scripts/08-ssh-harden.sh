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
#     备份 + 写新配置 + sshd -t + reload + 调度 deadman 自动回滚
#
#   confirm
#     新端口已验证可登录, 取消 deadman 自动回滚
#
#   rollback [--auto]
#     立即回滚到最近一次备份
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
    "${SUDO[@]}" atrm "$JOB_ID" 2>/dev/null || warn "atrm 失败（任务可能已超时执行）"
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
  [ "${1:-}" = "--auto" ] && AUTO=1

  LATEST=""
  if "${SUDO[@]}" test -d "$BACKUP_DIR"; then
    LATEST="$("${SUDO[@]}" sh -c "ls -1t '$BACKUP_DIR'/sshd-*.tar.gz 2>/dev/null | head -1" || true)"
  fi
  if [ -z "$LATEST" ]; then
    err "没有可用的备份, 无法回滚"
    exit 1
  fi

  if [ "$AUTO" -eq 1 ]; then
    warn "deadman 自动触发回滚（用户在窗口期内未 confirm）"
  else
    log "手动回滚到 $LATEST"
  fi

  # 移除 drop-in
  "${SUDO[@]}" rm -f "$SSHD_DROPIN_DIR/$DROPIN_NAME"
  # 解包恢复
  "${SUDO[@]}" tar xzf "$LATEST" -C /
  # 校验
  if ! "${SUDO[@]}" sshd -t 2>/dev/null; then
    err "回滚后 sshd -t 仍失败, 可能配置已损坏, 不要 reload sshd！"
    err "请人工 ssh 进去（旧端口的会话还活着）查 $SSHD_MAIN"
    exit 1
  fi
  "${SUDO[@]}" systemctl reload ssh 2>/dev/null || \
    "${SUDO[@]}" systemctl reload sshd 2>/dev/null || \
    err "reload sshd 失败"

  "${SUDO[@]}" rm -f "$DEADMAN_FILE"
  ok "已回滚到 $LATEST 并 reload sshd"
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

# --- 备份
TS="$(date +%Y%m%d-%H%M%S)"
"${SUDO[@]}" mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/sshd-$TS.tar.gz"
log "备份 /etc/ssh → $BACKUP_FILE"
"${SUDO[@]}" tar czf "$BACKUP_FILE" -C / etc/ssh/sshd_config etc/ssh/sshd_config.d 2>/dev/null || \
  "${SUDO[@]}" tar czf "$BACKUP_FILE" -C / etc/ssh/sshd_config 2>/dev/null
ok "备份完成"

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
  if [ "$USE_DROPIN" -eq 1 ]; then
    "${SUDO[@]}" rm -f "$SSHD_DROPIN_DIR/$DROPIN_NAME"
  fi
  "${SUDO[@]}" tar xzf "$BACKUP_FILE" -C /
  exit 1
fi
ok "sshd -t 通过"

# --- reload（不 restart, 保活当前会话）
log "systemctl reload sshd（保活当前会话）"
"${SUDO[@]}" systemctl reload ssh 2>/dev/null || \
  "${SUDO[@]}" systemctl reload sshd 2>/dev/null || \
  { err "reload 失败"; exit 1; }
ok "sshd reloaded"

# --- 调度 deadman
if [ "$USE_DEADMAN" -eq 1 ]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  ROLLBACK_CMD="bash $REPO_ROOT/scripts/08-ssh-harden.sh rollback --auto"
  log "调度 deadman: $ROLLBACK_MIN 分钟后自动回滚（除非你跑 confirm）"
  AT_OUT="$(echo "$ROLLBACK_CMD" | "${SUDO[@]}" at "now + $ROLLBACK_MIN minutes" 2>&1 || true)"
  echo "$AT_OUT" | grep -q '^job ' || { err "at 调度失败：$AT_OUT"; exit 1; }
  JOB_ID="$(echo "$AT_OUT" | grep -oP 'job \K[0-9]+' | head -1)"
  echo "$JOB_ID" | "${SUDO[@]}" tee "$DEADMAN_FILE" >/dev/null
  ok "deadman job=$JOB_ID, 将于 $ROLLBACK_MIN 分钟后触发自动回滚"
fi

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
