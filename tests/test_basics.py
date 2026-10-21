"""Isolated behavior regressions; run with .venv/bin/python -m unittest discover -s tests.

All repositories, HOME files and command stubs live in TemporaryDirectory. No
package manager, network connection or host configuration command is executed.
"""
import importlib.util
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'scripts'
BASH = '/bin/bash'
GIT = shutil.which('git')
SPEC = importlib.util.spec_from_file_location('managed_file', SCRIPTS / 'lib/managed_file.py')
MANAGED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MANAGED)


class IsolatedCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bootstrap-test-')
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / 'home'
        self.bin = self.base / 'bin'
        self.home.mkdir()
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), PATH=f'{self.bin}:/usr/bin:/bin',
                        GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(self.base / 'gitconfig'))
        for name in ('NVM_DIR', 'BASH_ENV', 'ENV', 'SUDO_USER', 'BOOTSTRAP_VENV', 'REPO_DIR'):
            self.env.pop(name, None)
        self.env['TRACE'] = str(self.base / 'trace')
        # A mistaken host mutation must fail before executing any real command.
        for name in ('sudo', 'apt-get', 'systemctl', 'chsh', 'service', 'pip', 'pip3'):
            self.stub(name, 'echo "forbidden command: $0 $*" >&2; exit 97')

    def stub(self, name, body, directory=None):
        path = (directory or self.bin) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('#!/bin/bash\nset -eu\n' + body + '\n')
        path.chmod(0o755)
        return path

    def run_cmd(self, *args, env=None, cwd=None, input=None):
        return subprocess.run([str(a) for a in args], env=env or self.env, cwd=cwd,
                              input=input, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=30)

    def good(self, result):
        self.assertEqual(result.returncode, 0, result.stdout)
        return result

    def shell(self, body, *args):
        return self.run_cmd(BASH, '-c', body, 'test', *args)

    def repo(self, files=None):
        source = self.base / 'source'
        source.mkdir()
        self.good(self.run_cmd(GIT, 'init', '-q', source))
        for name, text in (files or {'README': 'original\n'}).items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.good(self.run_cmd(GIT, '-C', source, 'add', '.'))
        self.good(self.run_cmd(GIT, '-C', source, '-c', 'user.name=Test',
                               '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture'))
        target = self.base / 'project'
        self.good(self.run_cmd(GIT, 'clone', '-q', source, target))
        return source, target

    def project(self, source, target, *extra):
        return self.run_cmd(BASH, SCRIPTS / '06-project.sh', '--repo', source,
                            '--dir', target, *extra)


class CommonTests(IsolatedCase):
    def common(self, body, *args):
        return self.shell('. "$1"; shift; ' + body, SCRIPTS / 'lib/common.sh', *args)

    def test_defaults_preserve_hostname_and_set_port_and_optional_runtimes(self):
        result = self.good(self.common('config_defaults; printf "%s|%s|%s|%s|%s|%s|%s" '
                                      '"$HOSTNAME_VALUE" "$SSH_PORT" "$TIMEZONE" '
                                      '"$INSTALL_NODE" "$INSTALL_BUN" "$INSTALL_ZSH" "$PROJECT_REPO"'))
        self.assertEqual(result.stdout, '|22022|Asia/Shanghai|no|no|no|')

    def test_port_bounds_and_decimal_leading_zero(self):
        for value in ('1', '22', '65535', '00022'):
            with self.subTest(value=value):
                self.good(self.common('valid_port "$1"', value))
        for value in ('', '0', '65536', '-22', '+22', '22.0', 'abc', '1 2', '000001', '22;true'):
            with self.subTest(value=value):
                self.assertNotEqual(self.common('valid_port "$1"', value).returncode, 0)

    def test_missing_parameter_and_invalid_hostname_rejected(self):
        self.assertNotEqual(self.common('config_defaults; parse_config --ssh-port').returncode, 0)
        self.assertNotEqual(self.common('valid_hostname "$1"', '-badhost').returncode, 0)
        self.good(self.common('valid_hostname "$1"', 'my-server'))

    def test_show_config_runs_without_optional_or_ai_tools(self):
        result = self.good(self.run_cmd(BASH, SCRIPTS / 'server-init.sh', '--show-config',
                                       '--hostname', '', '--ssh-port', '', '--timezone', ''))
        self.assertIn("SSH_PORT=''", result.stdout)
        self.assertIn("HOSTNAME_VALUE=''", result.stdout)
        self.assertFalse((self.base / 'trace').exists())


class ManagedFileTests(IsolatedCase):
    def test_preserve_custom_text_backup_mode_and_idempotence(self):
        path = self.home / '.bashrc'
        original = 'export USER_SETTING=keep\n# hand written\n'
        path.write_text(original)
        path.chmod(0o600)
        MANAGED.update(path, 'test', 'export MANAGED=value\n')
        first = path.read_bytes()
        self.assertTrue(path.read_text().startswith(original))
        self.assertEqual(Path(str(path) + '.server-bootstrap.bak').read_text(), original)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        MANAGED.update(path, 'test', 'export MANAGED=value\n')
        self.assertEqual(path.read_bytes(), first)
        MANAGED.update(path, 'test', 'export MANAGED=next\n')
        self.assertTrue(path.read_text().startswith(original))
        self.assertEqual(path.read_text().count('# BEGIN server-bootstrap:test'), 1)
        self.assertNotIn('MANAGED=value', path.read_text())

    def test_anchor_and_user_text_after_block_survive(self):
        path = self.home / '.zshrc'
        path.write_text('before\nsource "$ZSH/oh-my-zsh.sh"\nafter\n')
        MANAGED.update(path, 'theme', 'ZSH_THEME=first', r'^source ')
        MANAGED.update(path, 'theme', 'ZSH_THEME=second', r'^source ')
        text = path.read_text()
        self.assertLess(text.index('ZSH_THEME=second'), text.index('source '))
        self.assertTrue(text.endswith('after\n'))
        self.assertEqual(text.count('# BEGIN'), 1)

    def test_symlink_and_malformed_block_rejected_without_modification(self):
        target = self.home / 'real'
        target.write_text('keep\n')
        link = self.home / '.bashrc'
        link.symlink_to(target)
        with self.assertRaises(ValueError):
            MANAGED.update(link, 'test', 'replace')
        self.assertEqual(target.read_text(), 'keep\n')
        self.assertTrue(link.is_symlink())
        for content in ('# BEGIN server-bootstrap:test\nuser content\n',
                        '# END server-bootstrap:test\n# BEGIN server-bootstrap:test\n'):
            target.write_text(content)
            with self.assertRaises(ValueError):
                MANAGED.update(target, 'test', 'replace')
            self.assertEqual(target.read_text(), content)

    def test_legacy_migration_does_not_remove_following_user_lines(self):
        path = self.home / '.bashrc'
        path.write_text('# server-bootstrap:nvm-load (managed by old)\n'
                        'export NVM_DIR="$HOME/.nvm"\n'
                        '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n'
                        'export USER_SETTING=preserve\n')
        MANAGED.update(path, 'nvm-load', 'export NVM_DIR="$HOME/.nvm"')
        self.assertIn('export USER_SETTING=preserve\n', path.read_text())
        first = path.read_text()
        MANAGED.update(path, 'nvm-load', 'export NVM_DIR="$HOME/.nvm"')
        self.assertEqual(path.read_text(), first)


class WrapperTests(IsolatedCase):
    def test_uses_runtime_without_deleting_user_tools_or_symlinks(self):
        managed_bin = self.home / '.nvm/versions/node/test/bin'
        self.stub('node', 'echo managed', managed_bin)
        user_bin = self.home / '.local/bin'
        target = self.stub('user-node', 'echo user', user_bin)
        link = user_bin / 'node'
        link.symlink_to(target)
        (self.home / '.nvm/nvm.sh').write_text(
            'nvm() { [ "$1 $2" = "which current" ] && printf "%s\\n" '
            + shlex.quote(str(managed_bin / 'node')) + '; }\n')
        self.env['PATH'] = f'{user_bin}:{self.bin}:/usr/bin:/bin'
        before = target.read_bytes()
        result = self.good(self.run_cmd(BASH, SCRIPTS / 'lib/with-env.sh', '--', 'node'))
        self.assertEqual(result.stdout, 'managed\n')
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), target.resolve())
        self.assertEqual(target.read_bytes(), before)


class ProjectTests(IsolatedCase):
    def test_origin_mismatch_and_dirty_worktree_are_protected(self):
        source, target = self.repo()
        result = self.project(str(source) + '-different', target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((target / 'README').read_text(), 'original\n')
        (target / 'README').write_text('local work\n')
        result = self.project(source, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((target / 'README').read_text(), 'local work\n')
        self.assertFalse((target / '.server-bootstrap-prepared').exists())

    def test_existing_env_is_preserved_and_rerun_remains_clean(self):
        source, target = self.repo({'README': 'fixture\n', '.gitignore': '.env\n'})
        secret = target / '.env'
        secret.write_text('TOKEN=keep-this-local-value\n')
        secret.chmod(0o600)
        self.good(self.project(source, target, '--env-keys', 'TOKEN,NEW_KEY'))
        self.good(self.project(source, target, '--env-keys', 'TOKEN,NEW_KEY'))
        self.assertEqual(secret.read_text(), 'TOKEN=keep-this-local-value\n')
        self.assertEqual(stat.S_IMODE(secret.stat().st_mode), 0o600)
        self.assertEqual(self.good(self.run_cmd(GIT, '-C', target, 'status', '--porcelain')).stdout, '')

    def test_new_env_is_private_and_not_tracked(self):
        source, target = self.repo()
        self.good(self.project(source, target, '--env-keys', 'TOKEN,API_KEY'))
        self.assertEqual((target / '.env').read_text(), 'TOKEN=TODO\nAPI_KEY=TODO\n')
        self.assertEqual(stat.S_IMODE((target / '.env').stat().st_mode), 0o600)
        self.assertEqual(self.good(self.run_cmd(GIT, '-C', target, 'status', '--porcelain')).stdout, '')

    def test_python_dependencies_run_only_inside_project_venv(self):
        source, target = self.repo({'requirements.txt': '# no real package installation\n'})
        self.stub('python3', '''
[ "$*" = '-m venv .venv' ] || exit 96
mkdir -p .venv/bin
cat > .venv/bin/python <<'SH'
#!/bin/bash
printf 'venv:%s\\n' "$*" >> "$TRACE"
SH
chmod +x .venv/bin/python
''')
        self.good(self.project(source, target))
        self.good(self.project(source, target))
        self.assertEqual((self.base / 'trace').read_text().splitlines(),
                         ["venv:-c import sys; assert sys.prefix != sys.base_prefix", 'venv:-m pip install -r requirements.txt'] * 2)
        self.assertEqual(self.good(self.run_cmd(GIT, '-C', target, 'status', '--porcelain')).stdout, '')

    def test_lockfile_install_is_frozen_and_failure_has_no_success_receipt(self):
        source, target = self.repo({'package.json': '{}\n', 'package-lock.json': '{}\n'})
        self.stub('npm', 'printf "%s\\n" "$*" >> "$TRACE"; exit "${NPM_EXIT:-0}"')
        self.good(self.project(source, target))
        self.assertEqual((self.base / 'trace').read_text(), 'ci\n')
        self.env['NPM_EXIT'] = '7'
        result = self.project(source, target)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((target / '.server-bootstrap-prepared').exists())

    def test_uv_lock_uses_explicit_project_venv(self):
        source, target = self.repo({'pyproject.toml': '[project]\nname="fixture"\n', 'uv.lock': '# fixture\n'})
        self.stub('uv', 'printf "%s|%s\\n" "$UV_PROJECT_ENVIRONMENT" "$*" >> "$TRACE"')
        self.good(self.project(source, target))
        self.assertEqual((self.base / 'trace').read_text(), f'{target}/.venv|sync --frozen\n')


class VerifyTests(IsolatedCase):
    def verifier(self):
        scripts = self.base / 'scripts'
        shutil.copytree(SCRIPTS / 'lib', scripts / 'lib')
        os_release = self.base / 'os-release'
        os_release.write_text('ID=ubuntu\n')
        # Only relocate the OS metadata lookup; all verification logic is real.
        text = (SCRIPTS / 'verify-server.sh').read_text().replace('/etc/os-release', str(os_release))
        path = scripts / 'verify-server.sh'
        path.write_text(text)
        (self.base / 'gitconfig').write_text('[user]\n name = Fixture\n email = test@example.invalid\n')
        self.stub('curl', 'exit 0')
        self.stub('hostnamectl', 'echo fixture-host')
        self.stub('timedatectl', 'echo Asia/Shanghai')
        self.stub('id', '[ "$1" = -u ] && echo 0 || echo tester')
        self.env['BOOTSTRAP_VENV'] = str(ROOT / '.venv')
        return path

    def verify(self, path, *args):
        return self.run_cmd(BASH, path, '--harden-ssh', 'no', '--enable-fail2ban', 'no', *args)

    def test_missing_required_component_fails_and_optional_absence_skips(self):
        path = self.verifier()
        good = self.good(self.verify(path))
        self.assertIn('[跳过] Node', good.stdout)
        self.assertIn('[跳过] Bun', good.stdout)
        self.env['BOOTSTRAP_VENV'] = str(self.base / 'missing-venv')
        result = self.verify(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('[失败] 专用 Python venv', result.stdout)

    def test_requested_hostname_mismatch_is_failure(self):
        result = self.verify(self.verifier(), '--hostname', 'different-host')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('[失败] hostname=different-host', result.stdout)

    def test_missing_dependency_receipt_is_unverified(self):
        source, target = self.repo()
        result = self.verify(self.verifier(), '--repo', source, '--project-dir', target)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('[未验证]', result.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
