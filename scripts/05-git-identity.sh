#!/usr/bin/env bash
# 05-git-identity.sh — 配置 git 全局 user.name / user.email
#
# 用法：
#   bash 05-git-identity.sh --name "Your Name" --email you@example.com
#
# 幂等：值已正确则不重写。

set -euo pipefail

log()  { printf '\033[1;34m[05-git-identity]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

NAME=""
EMAIL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name)  NAME="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --name \"Your Name\" --email you@example.com"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

if [ -z "$NAME" ] || [ -z "$EMAIL" ]; then
  err "--name 和 --email 必须提供"
  exit 2
fi

# 简单邮箱格式校验（够用就行, 不上 RFC）
case "$EMAIL" in
  *@*.*) ;;
  *) err "邮箱格式看起来不对：$EMAIL"; exit 2 ;;
esac

if ! command -v git >/dev/null 2>&1; then
  err "git 不存在, 先跑 02-base-deps.sh"
  exit 1
fi

CUR_NAME="$(git config --global user.name  || true)"
CUR_EMAIL="$(git config --global user.email || true)"

if [ "$CUR_NAME" = "$NAME" ] && [ "$CUR_EMAIL" = "$EMAIL" ]; then
  ok "git 全局身份已是目标值, 跳过"
else
  log "设置 git user.name  = $NAME"
  git config --global user.name  "$NAME"
  log "设置 git user.email = $EMAIL"
  git config --global user.email "$EMAIL"
  ok "git 身份已写入 ~/.gitconfig"
fi

# 默认分支名（避免 main/master 警告）
if [ -z "$(git config --global init.defaultBranch || true)" ]; then
  git config --global init.defaultBranch main
  ok "init.defaultBranch = main"
fi

# 安全：禁用 askpass 弹窗（无 GUI 服务器上常见问题）
if [ -z "$(git config --global core.askPass || true)" ]; then
  git config --global core.askPass ""
fi

log "完成"
