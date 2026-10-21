"""Atomic, bounded updates to user-owned text files. Run with the helper venv."""
import argparse
import os
from pathlib import Path
import re
import shutil
import stat
import tempfile


def update(path, key, body, before=None):
    path = Path(path).expanduser()
    if path.is_symlink():
        raise ValueError(f"Refusing to replace symlink: {path}")
    original = path.read_text() if path.exists() else ""
    begin = f"# BEGIN server-bootstrap:{key}"
    end = f"# END server-bootstrap:{key}"
    if original.count(begin) != original.count(end) or original.count(begin) > 1 or (begin in original and original.index(end) < original.index(begin)):
        raise ValueError(f"Malformed managed block in {path}")
    pattern = r"(?m)^" + re.escape(begin) + r"\n[\s\S]*?^" + re.escape(end) + r"\n?"
    if len(re.findall(pattern, original)) != original.count(begin):
        raise ValueError(f"Malformed managed block in {path}")
    content = original
    # Old releases had no END marker. Remove only known generated lines, never
    # everything up to EOF. Unknown legacy text is preserved for manual review.
    legacy = {
        "nvm-load": [r'export NVM_DIR=.*', r'\[ -s "\$NVM_DIR/nvm.sh" \] && \. "\$NVM_DIR/nvm.sh"', r'\[ -s "\$NVM_DIR/bash_completion" \] && \. "\$NVM_DIR/bash_completion"'],
        "localbin-path": [r'case .*\$HOME/\.local/bin.*esac'],
        "bun-path": [r'export BUN_INSTALL=.*', r'case .*\$BUN_INSTALL/bin.*esac'],
    }
    lines = content.splitlines(keepends=True)
    for index in range(len(lines) - 1, -1, -1):
        if lines[index].startswith(f"# server-bootstrap:{key} (managed by "):
            count = 1
            for pattern in legacy.get(key, []):
                if index + count < len(lines) and re.fullmatch(pattern, lines[index + count].rstrip('\n')):
                    count += 1
                else:
                    break
            del lines[index:index + count]
    content = ''.join(lines)
    old_match = re.search(pattern, content)
    old_start = old_match.start() if old_match else -1
    content = re.sub(pattern, '', content)
    block = begin + '\n' + body.rstrip('\n') + '\n' + end + '\n'
    # Preserve the old insertion position so repeated writes are byte-stable.
    if before and re.search(before, content, re.M):
        position = re.search(before, content, re.M).start()
        content = content[:position] + block + content[position:]
    elif before:
        raise ValueError(f"Required insertion anchor not found in {path}")
    elif old_start >= 0:
        content = content[:old_start] + block + content[old_start:]
    else:
        content += ("\n" if content and not content.endswith('\n') else '') + block
    if content == original:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        shutil.copy2(path, str(path) + '.server-bootstrap.bak')
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == '__main__':
    import sys
    parser = argparse.ArgumentParser()
    parser.add_argument('path')
    parser.add_argument('key')
    parser.add_argument('--before')
    args = parser.parse_args()
    update(args.path, args.key, sys.stdin.read(), args.before)
