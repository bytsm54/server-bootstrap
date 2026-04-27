#!/usr/bin/env bash
# 07-plugins-skills.sh — 可选 phase：装 Claude Code plugins / skills
#
# 重要：本脚本 *不* 决定装什么。要装哪些必须由调用者（agent + 用户对话）从
# templates/plugins.yaml 和 templates/skills.yaml 中明确挑选, 通过 --selection
# 传一个 JSON 进来。脚本只负责执行命令。
#
# 用法：
#   bash 07-plugins-skills.sh \
#     --plugins-yaml <path> --skills-yaml <path> \
#     --selection '{"plugins":["superpowers"],"skills":["skill-creator"],"extra_plugins":[],"extra_skills":[]}'
#
# selection JSON 字段：
#   plugins:        templates/plugins.yaml 中要装的 id 列表
#   skills:         templates/skills.yaml 中要装的 id 列表
#   extra_plugins:  用户自定义的 plugin install 字符串列表（如 "name@source"）
#   extra_skills:   用户自定义的 skill install 字符串列表（如 "user/repo@skill-name"）

set -euo pipefail

log()  { printf '\033[1;34m[07-plugins-skills]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ⚠️\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

PLUGINS_YAML=""
SKILLS_YAML=""
SELECTION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plugins-yaml) PLUGINS_YAML="$2"; shift 2 ;;
    --skills-yaml)  SKILLS_YAML="$2";  shift 2 ;;
    --selection)    SELECTION="$2";    shift 2 ;;
    -h|--help)
      echo "Usage: $0 --plugins-yaml <path> --skills-yaml <path> --selection <json>"
      exit 0 ;;
    *) err "未知参数: $1"; exit 2 ;;
  esac
done

if ! command -v python3 >/dev/null 2>&1; then
  err "需要 python3 解析 yaml 和 json, 没找到"
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  err "claude CLI 不在 PATH, 用 with-env.sh 包装本脚本：bash lib/with-env.sh -- bash 07-plugins-skills.sh ..."
  exit 1
fi
if ! command -v npx >/dev/null 2>&1; then
  err "npx 不在 PATH（同上, 用 with-env.sh 包装）"
  exit 1
fi

if [ -z "$SELECTION" ]; then
  warn "--selection 为空, 没有要装的 plugin / skill, 退出"
  exit 0
fi

# --- 用 python 解析 yaml + selection, 输出要执行的 install 命令
mapfile -t COMMANDS < <(
  python3 - "$PLUGINS_YAML" "$SKILLS_YAML" "$SELECTION" <<'PY'
import json, sys, os, re

p_yaml, s_yaml, selection_raw = sys.argv[1], sys.argv[2], sys.argv[3]

def load_yaml_lite(path):
    """极简 yaml 解析：只支持 plugins/skills 顶层 list, 每条带 id/install/description/side_effects"""
    if not path or not os.path.exists(path):
        return {"plugins": [], "skills": []}
    out_plugins, out_skills = [], []
    with open(path) as f:
        text = f.read()
    # 用 PyYAML 如果有
    try:
        import yaml
        data = yaml.safe_load(text) or {}
        return {
            "plugins": data.get("plugins") or [],
            "skills":  data.get("skills")  or [],
        }
    except ImportError:
        pass
    # 退化：极简手解（容错有限, 但模板格式我们自己定的）
    cur_section, cur_item, items = None, None, []
    section_items = {"plugins": [], "skills": []}
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if re.match(r"^plugins\s*:\s*$", line):
            if cur_item: items.append(cur_item); cur_item = None
            if cur_section: section_items[cur_section] = items
            cur_section, items = "plugins", []
            continue
        if re.match(r"^skills\s*:\s*$", line):
            if cur_item: items.append(cur_item); cur_item = None
            if cur_section: section_items[cur_section] = items
            cur_section, items = "skills", []
            continue
        if re.match(r"^\s*-\s+", line):
            if cur_item: items.append(cur_item)
            cur_item = {}
            line = re.sub(r"^\s*-\s+", "", line)
            if ":" in line:
                k, v = line.split(":", 1)
                cur_item[k.strip()] = v.strip().strip('"').strip("'")
            continue
        m = re.match(r"^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", line)
        if m and cur_item is not None:
            cur_item[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    if cur_item: items.append(cur_item)
    if cur_section: section_items[cur_section] = items
    return section_items

plugins_yaml = load_yaml_lite(p_yaml)
skills_yaml  = load_yaml_lite(s_yaml)

selection = json.loads(selection_raw)

def find_install(items, item_id):
    for it in items:
        if it.get("id") == item_id:
            return it.get("install") or ""
    return None

cmds = []

for pid in selection.get("plugins", []) or []:
    inst = find_install(plugins_yaml.get("plugins") or [], pid)
    if not inst:
        print(f"echo 'WARN: plugin id {pid} not found in plugins.yaml, 跳过' >&2", file=sys.stdout)
        continue
    cmds.append(f"claude plugins install {inst}")

for sid in selection.get("skills", []) or []:
    inst = find_install(skills_yaml.get("skills") or [], sid)
    if not inst:
        print(f"echo 'WARN: skill id {sid} not found in skills.yaml, 跳过' >&2", file=sys.stdout)
        continue
    cmds.append(f"npx skills add {inst} -g -y")

for raw in selection.get("extra_plugins", []) or []:
    if raw.strip():
        cmds.append(f"claude plugins install {raw.strip()}")

for raw in selection.get("extra_skills", []) or []:
    if raw.strip():
        cmds.append(f"npx skills add {raw.strip()} -g -y")

for c in cmds:
    print(c)
PY
)

if [ "${#COMMANDS[@]}" -eq 0 ]; then
  warn "没有可执行的 install 命令, selection 是空或全没匹配上"
  exit 0
fi

# --- 执行
log "将执行 ${#COMMANDS[@]} 条 install 命令"
for c in "${COMMANDS[@]}"; do
  log "→ $c"
  # shellcheck disable=SC2086
  if ! eval "$c"; then
    err "失败：$c"
    err "继续下一个（不让一个失败拖垮整个 phase）"
  fi
done

log "完成。可用 verify.sh 检查最终安装数量。"
