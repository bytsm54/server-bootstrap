#!/usr/bin/env bash
# Only the creation of the environment uses the system interpreter.
ensure_python_env() {
  local repo_root
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  BOOTSTRAP_VENV="${BOOTSTRAP_VENV:-$repo_root/.venv}"
  if [ ! -x "$BOOTSTRAP_VENV/bin/python" ]; then
    python3 -m venv "$BOOTSTRAP_VENV" || {
      echo '无法创建 venv；请先安装 python3-venv 并检查仓库目录权限' >&2
      return 1
    }
  fi
  BOOTSTRAP_PYTHON="$BOOTSTRAP_VENV/bin/python"
  "$BOOTSTRAP_PYTHON" -c 'import sys; assert sys.prefix != sys.base_prefix' || {
    echo '辅助 Python 不是有效 venv，拒绝回退到系统解释器' >&2; return 1;
  }
}
