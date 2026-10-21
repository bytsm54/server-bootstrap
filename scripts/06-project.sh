#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO=''; DIR=''; ENV_KEYS=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || exit 2
  case "$1" in --repo) REPO="$2" ;; --dir) DIR="$2" ;; --env-keys) ENV_KEYS="$2" ;; *) exit 2 ;; esac
  shift 2
done
[ -n "$REPO" ] && [[ "$REPO" != -* ]] || { echo '需要有效 --repo' >&2; exit 2; }
if [ -n "$ENV_KEYS" ] && ! [[ "$ENV_KEYS" =~ ^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
  echo 'env-keys 只能为逗号分隔的环境变量名' >&2; exit 2
fi
DIR="${DIR:-$HOME/$(basename "$REPO" .git)}"
if [ -d "$DIR/.git" ] || [ -f "$DIR/.git" ]; then
  [ "$(git -C "$DIR" remote get-url origin)" = "$REPO" ] || { echo '项目目录的 origin 与请求不符' >&2; exit 1; }
  [ -z "$(git -C "$DIR" status --porcelain)" ] || { echo '项目存在本地改动，请先处理再安装依赖' >&2; exit 1; }
  echo '复用当前项目版本；不自动拉取或切换版本'
elif [ -e "$DIR" ]; then
  echo '目标目录存在且不是 Git 仓库' >&2; exit 1
else
  git clone -- "$REPO" "$DIR"
fi
cd "$DIR"
exclude="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude")"
for ignored in .venv/ .server-bootstrap-prepared; do
  grep -qxF "$ignored" "$exclude" 2>/dev/null || printf '%s\n' "$ignored" >> "$exclude"
done
if git ls-files --error-unmatch .server-bootstrap-prepared >/dev/null 2>&1 || [ -L .server-bootstrap-prepared ]; then
  echo '项目准备记录路径与已有文件冲突，拒绝覆盖' >&2; exit 1
fi
rm -f .server-bootstrap-prepared
require_tool() { command -v "$1" >/dev/null || { echo "需要 $1；请先启用相应运行环境" >&2; return 1; }; }
if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f uv.lock ] || [ -f poetry.lock ] || [ -f pdm.lock ] || [ -f Pipfile.lock ]; then
  if [ -f poetry.lock ] || [ -f pdm.lock ] || [ -f Pipfile.lock ]; then
    echo '此项目使用尚未支持的 Python 锁文件；请使用对应管理器显式同步到项目 venv' >&2; exit 1
  elif [ -f uv.lock ]; then
    require_tool uv
    UV_PROJECT_ENVIRONMENT="$PWD/.venv" uv sync --frozen
  else
    [ -x .venv/bin/python ] || python3 -m venv .venv
    .venv/bin/python -c 'import sys; assert sys.prefix != sys.base_prefix'
    if [ -f pyproject.toml ]; then .venv/bin/python -m pip install -e .
    else .venv/bin/python -m pip install -r requirements.txt; fi
  fi
elif [ -f package.json ]; then
  if [ -f pnpm-lock.yaml ]; then require_tool pnpm; pnpm install --frozen-lockfile
  elif [ -f yarn.lock ]; then
    require_tool yarn
    case "$(yarn --version)" in 1.*) yarn install --frozen-lockfile ;; *) yarn install --immutable ;; esac
  elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then require_tool npm; npm ci
  elif [ -f bun.lock ] || [ -f bun.lockb ]; then require_tool bun; bun install --frozen-lockfile
  else require_tool npm; npm install; fi
elif [ -f Cargo.toml ]; then require_tool cargo; cargo build --locked
elif [ -f go.mod ]; then require_tool go; go mod download
else echo '未识别项目依赖清单；已克隆，依赖阶段跳过'; fi
if [ -n "$ENV_KEYS" ]; then
  [ ! -L .env ] || { echo ".env 是软链，拒绝写入" >&2; exit 1; }
  if [ ! -e .env ]; then
    (umask 077; IFS=',' read -r -a keys <<< "$ENV_KEYS"; printf '%s=TODO\n' "${keys[@]}" > .env)
  fi
  if ! git check-ignore -q .env; then
    # Repo-local exclusion does not change a tracked .gitignore.
    exclude="$(git rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "$exclude")"
    printf '\n.env\n.venv/\n' >> "$exclude"
  fi
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then
    echo '.env 已被 Git 跟踪，请先从索引移除再填写凭据' >&2; exit 1
  fi
fi
git rev-parse HEAD > .server-bootstrap-prepared
printf '项目准备完成: %s\n' "$DIR"
