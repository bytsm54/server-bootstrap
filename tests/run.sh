#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[ -x .venv/bin/python ] || python3 -m venv .venv
.venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
bash tests/node-domestic-mirrors.sh
while IFS= read -r script; do bash -n "$script"; done < <(find scripts tests -name '*.sh' -type f)
git diff --check
