#!/usr/bin/env bash
# 03-node.sh — 安装 nvm 到 ~/.nvm 并通过它装 Node（用户态, 无 sudo）
#
# 用法：
#   bash 03-node.sh [--node-version lts|<ver>] [--npm-registry official|china]
#
# 幂等：
#   - nvm 已装 → 跳过 nvm 安装, 仅按需切版本
#   - 目标 node 版本已装 → 仅 nvm use
#   - 设置/取消 npm 镜像也是幂等的

# 注意：故意不用 -u（set -u）。nvm 内部有代码路径引用未初始化的 PROVIDED_VERSION
# 等变量, 在 -u 下会触发 "unbound variable" 中断 nvm install。这是 nvm 已知的兼容
# 性问题（见 nvm-sh/nvm 多个 issue）。我们仍保留 -e 和 -o pipefail。
set -eo pipefail

log()  { printf '\033[1;34m[03-node]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✅\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m  ❌\033[0m %s\n' "$*" >&2; }

NODE_VERSION="lts"
NPM_REGISTRY="official"
NVM_INSTALLER_TAG="${NVM_INSTALLER_TAG:-v0.40.3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --node-version) NODE_VERSION="$2"; shift 2 ;;
    --npm-registry) NPM_REGISTRY="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--node-version lts|<ver>] [--npm-registry official|china]"
      exit 0
      ;;
    *)
      err "未知参数: $1"; exit 2 ;;
  esac
done

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

# --- 1. 装 nvm（如果没装）
if [ -s "$NVM_DIR/nvm.sh" ]; then
  ok "nvm 已存在 ($NVM_DIR)"
else
  log "安装 nvm $NVM_INSTALLER_TAG 到 $NVM_DIR"
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_INSTALLER_TAG/install.sh" | bash
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    err "nvm 安装后 $NVM_DIR/nvm.sh 仍不存在"
    exit 1
  fi
  ok "nvm 安装完成"
fi

# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"

# --- 2. 装 / 切换 Node
case "$NODE_VERSION" in
  lts|LTS)
    if nvm ls --no-colors | grep -qE 'lts/\* +\->'; then
      ok "Node LTS 已装"
    else
      log "nvm install --lts"
      nvm install --lts
    fi
    nvm use --lts >/dev/null
    nvm alias default 'lts/*' >/dev/null || true
    ;;
  *)
    if nvm ls --no-colors | grep -qE "v?$NODE_VERSION([^0-9]|\$)"; then
      ok "Node $NODE_VERSION 已装"
    else
      log "nvm install $NODE_VERSION"
      nvm install "$NODE_VERSION"
    fi
    nvm use "$NODE_VERSION" >/dev/null
    nvm alias default "$NODE_VERSION" >/dev/null || true
    ;;
esac

ok "Node: $(node --version)"
ok "npm:  $(npm --version)"
ok "npx:  $(npx --version)"

# --- 3. npm 镜像
case "$NPM_REGISTRY" in
  china)
    log "切换 npm registry → npmmirror.com"
    npm config set registry https://registry.npmmirror.com
    ;;
  official|"")
    if [ "$(npm config get registry)" != "https://registry.npmjs.org/" ]; then
      log "重置 npm registry → 官方"
      npm config delete registry || true
    fi
    ;;
  *)
    err "--npm-registry 必须是 official 或 china（你给了 $NPM_REGISTRY）"
    exit 2
    ;;
esac

ok "registry: $(npm config get registry)"

# --- 4. bun（用户态, claude-mem 等 plugin 的 SessionStart hook 依赖）
# 装到 ~/.bun/bin/bun, 不需要 sudo。
if [ -x "$HOME/.bun/bin/bun" ]; then
  ok "bun: $("$HOME/.bun/bin/bun" --version) (已装)"
else
  log "装 bun (用户态)"
  if ! curl -fsSL https://bun.sh/install | bash; then
    err "bun 安装失败"
    exit 1
  fi
  if [ ! -x "$HOME/.bun/bin/bun" ]; then
    err "bun installer 跑完但 ~/.bun/bin/bun 不存在"
    exit 1
  fi
  ok "bun: $("$HOME/.bun/bin/bun" --version)"
fi

# 管理 bun PATH 在 .bashrc / .zshrc / .zshenv 三个 rc 文件:
#   - 用我们自己的 marker 块, 幂等
#   - 清掉 bun installer 留下的 "# bun" 旧块 (installer 不幂等, 跑两次会重复)
#   - .zshenv 关键: claude-mem 的 SessionStart hook 用 zsh -lc 跑命令, 这种
#     非交互登录 shell 不读 .zshrc, 只读 .zshenv / .zprofile。少了这步, hook
#     启动后报 "Bun not found"
log "管理 bun PATH 注入 (.bashrc / .zshrc / .zshenv)"
python3 - <<'PY'
import os, re
HOME = os.environ['HOME']
MARKER = '# server-bootstrap:bun-path (managed by 03-node.sh, do not edit)'
BLOCK = (
    MARKER + '\n'
    'export BUN_INSTALL="$HOME/.bun"\n'
    'case ":$PATH:" in *":$BUN_INSTALL/bin:"*) ;; *) export PATH="$BUN_INSTALL/bin:$PATH" ;; esac\n'
)
# bun installer 的标准块: # bun \n export BUN_INSTALL=... \n export PATH=...BUN_INSTALL...
INSTALLER_BLOCK_RE = re.compile(
    r'\n*# bun\nexport BUN_INSTALL=[^\n]*\nexport PATH=[^\n]*BUN_INSTALL[^\n]*\n',
    re.MULTILINE,
)

def manage(path):
    if not os.path.exists(path):
        open(path, 'a').close()
    with open(path) as f:
        content = f.read()
    new, removed = INSTALLER_BLOCK_RE.subn('', content)
    actions = []
    if removed:
        actions.append(f'清掉 {removed} 个 installer 旧块')
    if MARKER not in new:
        if new and not new.endswith('\n'):
            new += '\n'
        new += '\n' + BLOCK
        actions.append('追加 marker 块')
    if not actions:
        actions.append('已是目标状态')
    if new != content:
        with open(path, 'w') as f:
            f.write(new)
    print(f'  ✅ {os.path.basename(path)}: ' + ' / '.join(actions))

for rc in ('.bashrc', '.zshrc', '.zshenv'):
    manage(os.path.join(HOME, rc))
PY

log "完成"
