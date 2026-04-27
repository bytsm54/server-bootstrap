#!/usr/bin/env bash
# 02a-system.sh — 系统级配置：hostname + timezone
#
# 用法：
#   bash 02a-system.sh [--hostname <name>] [--timezone <tz>]
#
# 行为：
#   - --hostname 给了：hostnamectl set-hostname + 同步 /etc/hosts 127.0.1.1
#   - --timezone 给了：timedatectl set-timezone + 校验 zoneinfo 存在
#   - 两个都为空：整个 phase 跳过
#
# 幂等：当前值 == 目标值 → 跳过。

set -euo pipefail

log()  { printf '\033[1;34m[02a-system]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

NEW_HOSTNAME=""
NEW_TZ=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hostname) NEW_HOSTNAME="$2"; shift 2 ;;
    --timezone) NEW_TZ="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--hostname <name>] [--timezone <tz>]"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

if [ -z "$NEW_HOSTNAME" ] && [ -z "$NEW_TZ" ]; then
  ok "hostname / timezone 都没要求, 整个 phase 跳过"
  exit 0
fi

# --- sudo
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "本 phase 改 hostname / timezone 需要 sudo, 但 sudo 不可用"
    exit 1
  fi
  SUDO=(sudo)
else
  SUDO=()
fi

# --- hostname
if [ -n "$NEW_HOSTNAME" ]; then
  CUR_HOST="$(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || echo '')"
  if [ "$CUR_HOST" = "$NEW_HOSTNAME" ]; then
    ok "hostname 已是 $NEW_HOSTNAME, 跳过"
  else
    # 校验：RFC 1123, 只允许 a-z 0-9 . -, 长度 ≤ 63, 不以 - 开头/结尾
    case "$NEW_HOSTNAME" in
      ""|-*|*-) err "hostname 不合法: '$NEW_HOSTNAME'"; exit 2 ;;
      *[!a-zA-Z0-9.-]*) err "hostname 只能含字母数字和 . -"; exit 2 ;;
    esac
    if [ "${#NEW_HOSTNAME}" -gt 63 ]; then
      err "hostname 长度超 63 字符"; exit 2
    fi

    log "hostname: $CUR_HOST → $NEW_HOSTNAME"
    "${SUDO[@]}" hostnamectl set-hostname "$NEW_HOSTNAME"

    # 同步 /etc/hosts 的 127.0.1.1 行（Ubuntu / Debian 惯例）
    if "${SUDO[@]}" grep -qE '^127\.0\.1\.1' /etc/hosts; then
      "${SUDO[@]}" sed -i.bak -E "s|^(127\.0\.1\.1[[:space:]]+).*|\1$NEW_HOSTNAME|" /etc/hosts
      ok "/etc/hosts 已更新（备份 /etc/hosts.bak）"
    else
      echo "127.0.1.1 $NEW_HOSTNAME" | "${SUDO[@]}" tee -a /etc/hosts >/dev/null
      ok "/etc/hosts 已追加 127.0.1.1 → $NEW_HOSTNAME"
    fi

    ok "hostname → $NEW_HOSTNAME（部分缓存的服务可能需重启 / 重连才显示新名）"
  fi
fi

# --- timezone
if [ -n "$NEW_TZ" ]; then
  CUR_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo '')"
  if [ "$CUR_TZ" = "$NEW_TZ" ]; then
    ok "timezone 已是 $NEW_TZ, 跳过"
  else
    if [ ! -f "/usr/share/zoneinfo/$NEW_TZ" ]; then
      err "timezone '$NEW_TZ' 在 /usr/share/zoneinfo 找不到"
      err "格式参考 'Asia/Shanghai', 'America/New_York', 'UTC' 等"
      exit 2
    fi
    log "timezone: $CUR_TZ → $NEW_TZ"
    "${SUDO[@]}" timedatectl set-timezone "$NEW_TZ"
    ok "timezone → $NEW_TZ（当前时间: $(date))"
  fi
fi

log "完成"
