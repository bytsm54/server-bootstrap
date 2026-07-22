#!/usr/bin/env bash
# 02-base-deps.sh — 安装 apt 基础依赖
# 只在以下任一不存在时调用 sudo apt：
#   - curl
#   - git
#   - python3
#   - util-linux（提供 flock，串行化 SSH 状态转换）
#   - ca-certificates 包
#   - build-essential 包（部分 npm 原生模块需要）
#
# 全部已装 → 直接退出 0, 不动 sudo。

set -euo pipefail

log()  { printf '\033[1;34m[02-base-deps]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

PKGS=(curl ca-certificates git build-essential at fonts-powerline python3 util-linux)

# 缺啥
MISSING=()
for p in "${PKGS[@]}"; do
  case "$p" in
    curl|git|at|python3)
      command -v "$p" >/dev/null 2>&1 || MISSING+=("$p")
      ;;
    *)
      dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p")
      ;;
  esac
done

if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "基础依赖齐全, 跳过 apt 阶段"
  exit 0
fi

log "需安装：${MISSING[*]}"

# --- sudo 前置
if [ "$(id -u)" -ne 0 ]; then
  if ! command -v sudo >/dev/null 2>&1; then
    err "需要 sudo 安装 ${MISSING[*]}, 但 sudo 不可用"
    err "请用 root 运行, 或先安装 sudo"
    exit 1
  fi
  SUDO=(sudo)
else
  SUDO=()
fi

log "sudo apt-get update"
"${SUDO[@]}" apt-get update -y

log "sudo apt-get install -y --no-install-recommends ${MISSING[*]}"
"${SUDO[@]}" apt-get install -y --no-install-recommends "${MISSING[@]}"

# 校验
for p in "${MISSING[@]}"; do
  case "$p" in
    curl|git|at|python3)
      command -v "$p" >/dev/null 2>&1 || { err "$p 装完仍找不到"; exit 1; }
      ;;
    *)
      dpkg -s "$p" >/dev/null 2>&1   || { err "$p 包未正确安装"; exit 1; }
      ;;
  esac
  ok "$p 安装完成"
done

# 启用 atd（08-ssh-harden 的 deadman 依赖）
if command -v at >/dev/null 2>&1; then
  if ! "${SUDO[@]}" systemctl is-active --quiet atd 2>/dev/null \
       && ! "${SUDO[@]}" systemctl is-active --quiet at-daemon 2>/dev/null; then
    log "启用 atd 服务"
    "${SUDO[@]}" systemctl enable --now atd 2>/dev/null || \
      "${SUDO[@]}" systemctl enable --now at-daemon 2>/dev/null || \
      log "atd 启用失败（08-ssh-harden 用到时再处理）"
  fi
fi

log "完成"
