#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/project-tools.sh"
REPO=''; DIR=''; ENV_KEYS=''
while [ "$#" -gt 0 ]; do
  case "$1" in -h|--help) echo 'Usage: 06-project.sh --repo url [--dir path] [--env-keys key,...]'; exit 0 ;; esac
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
if [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f uv.lock ] || [ -f poetry.lock ] || [ -f pdm.lock ] || [ -f Pipfile.lock ]; then
  if [ -f poetry.lock ] || [ -f pdm.lock ] || [ -f Pipfile.lock ]; then
    echo '此项目使用尚未支持的 Python 锁文件；请使用对应管理器显式同步到项目 venv' >&2; exit 1
  fi
  prepare_build_tools python3-dev
  if [ -f uv.lock ] || [ -f pyproject.toml ]; then
    prepare_uv
    if [ -f uv.lock ]; then UV_PROJECT_ENVIRONMENT="$PWD/.venv" uv sync --frozen
    else
      # A generated lock stays local until the owner decides to track it.
      grep -qxF uv.lock "$exclude" 2>/dev/null || printf '%s\n' uv.lock >> "$exclude"
      UV_PROJECT_ENVIRONMENT="$PWD/.venv" uv sync
    fi
  else
    [ -x .venv/bin/python ] || python3 -m venv .venv
    .venv/bin/python -c 'import sys; assert sys.prefix != sys.base_prefix'
    .venv/bin/python -m pip install -r requirements.txt
  fi
elif [ -f package.json ]; then
  ensure_python_env
  # Parse metadata without executing repository code. Reject ambiguous lock families.
  SELECTION="$("$BOOTSTRAP_PYTHON" "$SCRIPT_DIR/lib/project_metadata.py")"
  IFS='|' read -r manager version locked <<< "$SELECTION"
  prepare_build_tools
  case "$manager" in
    pnpm|yarn)
      prepare_node_manager "$manager" "$version"
      if [ "$manager" = pnpm ]; then
        if [ "$locked" = yes ]; then "${MANAGER[@]}" install --frozen-lockfile; else "${MANAGER[@]}" install; fi
      elif [ "$locked" = no ]; then "${MANAGER[@]}" install
      else
        case "$("${MANAGER[@]}" --version)" in 1.*) "${MANAGER[@]}" install --frozen-lockfile ;; *) "${MANAGER[@]}" install --immutable ;; esac
      fi ;;
    npm)
      if [ -n "$version" ]; then prepare_node_manager npm "$version"; else require_tool npm; MANAGER=(npm); fi
      if [ "$locked" = yes ]; then "${MANAGER[@]}" ci; else "${MANAGER[@]}" install; fi ;;
    bun)
      require_tool bun
      if [ -n "$version" ] && [ "$(bun --version)" != "${version%%+*}" ]; then echo 'Bun 版本与 packageManager 不符，请先准备请求的版本' >&2; exit 1; fi
      if [ "$locked" = yes ]; then bun install --frozen-lockfile; else bun install; fi ;;
  esac
elif [ -f Cargo.toml ]; then require_tool cargo; prepare_build_tools; cargo build --locked
elif [ -f go.mod ]; then require_tool go; prepare_build_tools; go mod download
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
