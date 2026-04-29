#!/usr/bin/env bash
# 09-fail2ban.sh — 装 fail2ban + 配 sshd jail
#
# 用法：
#   bash 09-fail2ban.sh --ssh-port <N> [--max-retry <N>] [--ban-time <sec>] [--find-time <sec>]
#
# 行为：
#   1. apt 装 fail2ban（已装则跳过）
#   2. 写 /etc/fail2ban/jail.d/sshd.local（监听 ssh-port）
#   3. systemctl enable + start fail2ban
#   4. 用 fail2ban-client status sshd 验证 jail 已激活
#
# 顺序提醒：必须在 phase 08 之后跑 — fail2ban 的 jail port 要跟实际 sshd 端口一致。
#           bootstrap 调用方应把 phase 08 用的 ssh_port 透传到 --ssh-port。
#
# 默认 jail 参数：findtime=10min, maxretry=5, bantime=1h（standard SSH brute-force defense）。
#
# 幂等：jail 文件内容不变 → 跳过 reload。

set -euo pipefail

log()  { printf '\033[1;34m[09-fail2ban]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

SSH_PORT=""
MAX_RETRY=5
BAN_TIME=3600
FIND_TIME=600

while [ $# -gt 0 ]; do
  case "$1" in
    --ssh-port)  SSH_PORT="$2";  shift 2 ;;
    --max-retry) MAX_RETRY="$2"; shift 2 ;;
    --ban-time)  BAN_TIME="$2";  shift 2 ;;
    --find-time) FIND_TIME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

# --- 参数校验
if [ -z "$SSH_PORT" ]; then
  err "必填: --ssh-port <N>（fail2ban 监听哪个端口）"
  err "如果 phase 08 把 sshd 改到了 22022, 这里就传 22022"
  exit 2
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
  err "--ssh-port 必须 1-65535（你给了 $SSH_PORT）"
  exit 2
fi
for var in MAX_RETRY BAN_TIME FIND_TIME; do
  val="${!var}"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ]; then
    err "--$(echo "$var" | tr '[:upper:]_' '[:lower:]-') 必须正整数（你给了 $val）"
    exit 2
  fi
done

# --- sudo
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "本 phase 改 /etc/fail2ban + systemctl, 需要 sudo, 但不可用"
    exit 1
  fi
  SUDO=(sudo)
else
  SUDO=()
fi

# --- 1. apt 装 fail2ban
if dpkg -s fail2ban >/dev/null 2>&1; then
  ok "fail2ban 已装"
else
  log "apt 安装 fail2ban"
  "${SUDO[@]}" apt-get update -y
  "${SUDO[@]}" apt-get install -y --no-install-recommends fail2ban
  ok "fail2ban 安装完成"
fi

# --- 2. 写 sshd jail
JAIL_FILE=/etc/fail2ban/jail.d/sshd.local
NEW_CONF=$(cat <<EOF
# Managed by server-bootstrap 09-fail2ban
# 想还原默认: sudo rm $JAIL_FILE && sudo systemctl reload fail2ban
[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = $MAX_RETRY
findtime = $FIND_TIME
bantime  = $BAN_TIME
# systemd backend 直接读 journal, 不依赖 /var/log/auth.log
# (Ubuntu 22.04+ minimal 不一定装 rsyslog, auth.log 可能不存在)
backend  = systemd
EOF
)

NEEDS_RELOAD=0
if "${SUDO[@]}" test -f "$JAIL_FILE"; then
  CUR_CONF="$("${SUDO[@]}" cat "$JAIL_FILE")"
  if [ "$CUR_CONF" = "$NEW_CONF" ]; then
    ok "$JAIL_FILE 内容已是目标值"
  else
    log "更新 $JAIL_FILE"
    echo "$NEW_CONF" | "${SUDO[@]}" tee "$JAIL_FILE" >/dev/null
    NEEDS_RELOAD=1
  fi
else
  log "写 $JAIL_FILE"
  echo "$NEW_CONF" | "${SUDO[@]}" tee "$JAIL_FILE" >/dev/null
  NEEDS_RELOAD=1
fi
"${SUDO[@]}" chmod 644 "$JAIL_FILE"

# --- 3. enable + start + (reload if needed)
if ! "${SUDO[@]}" systemctl is-enabled --quiet fail2ban 2>/dev/null; then
  log "enable fail2ban（开机自启）"
  "${SUDO[@]}" systemctl enable fail2ban >/dev/null 2>&1 || warn "systemctl enable 失败"
fi

if ! "${SUDO[@]}" systemctl is-active --quiet fail2ban 2>/dev/null; then
  log "启动 fail2ban"
  "${SUDO[@]}" systemctl start fail2ban
  ok "fail2ban 已启动"
elif [ "$NEEDS_RELOAD" -eq 1 ]; then
  log "reload fail2ban（应用新 jail 配置）"
  if ! "${SUDO[@]}" systemctl reload fail2ban 2>/dev/null; then
    "${SUDO[@]}" systemctl restart fail2ban
  fi
  ok "fail2ban 已 reload"
else
  ok "fail2ban 已运行, 配置无变化"
fi

# --- 4. 校验 jail 激活
sleep 1
if "${SUDO[@]}" fail2ban-client status sshd >/dev/null 2>&1; then
  ok "fail2ban sshd jail 激活, 端口=$SSH_PORT, maxretry=$MAX_RETRY, findtime=${FIND_TIME}s, bantime=${BAN_TIME}s"
else
  err "fail2ban-client status sshd 失败"
  err "排查: sudo systemctl status fail2ban; sudo journalctl -u fail2ban -n 50"
  exit 1
fi

log "完成"
