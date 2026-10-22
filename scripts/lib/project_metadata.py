"""Choose a package manager without running package.json scripts. Use helper venv."""
import json
from pathlib import Path
import re


def selection(root):
    data = json.loads((root / 'package.json').read_text())
    pinned = data.get('packageManager', '')
    match = re.fullmatch(r'(npm|pnpm|yarn|bun)@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+sha(?:224|256|384|512)\.[0-9a-f]+)?)', pinned)
    if pinned and not match:
        raise ValueError('packageManager 必须包含支持的管理器和确切版本')
    locks = [name for name, files in {
        'npm': ('package-lock.json', 'npm-shrinkwrap.json'), 'pnpm': ('pnpm-lock.yaml',),
        'yarn': ('yarn.lock',), 'bun': ('bun.lock', 'bun.lockb'),
    }.items() if any((root / path).exists() for path in files)]
    if len(locks) > 1 or (locks and match and locks[0] != match[1]):
        raise ValueError('锁文件或 packageManager 相互冲突；请明确项目使用的管理器')
    manager = match[1] if match else (locks[0] if locks else 'npm')
    return manager, match[2] if match else '', 'yes' if locks else 'no'


if __name__ == '__main__':
    print('|'.join(selection(Path.cwd())))
