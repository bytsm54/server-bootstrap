"""Behavior regressions for upgrading older non-AI configurations."""
import importlib.util
from pathlib import Path
import shutil
import unittest
from test_basics import IsolatedCase, SCRIPTS, ROOT, BASH, MANAGED


class Compatibility(IsolatedCase):
    def test_legacy_block_does_not_duplicate_or_remove_manual_completion(self):
        path = self.home / '.bashrc'
        content = ('# server-bootstrap:nvm-load (managed by old)\n'
                   'export NVM_DIR="$HOME/.nvm"\n'
                   '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"\n'
                   '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"\n'
                   '# custom completion follows\n'
                   '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"\n')
        path.write_text(content)
        MANAGED.update(path, 'nvm-load', 'echo new')
        self.assertIn('# custom completion follows\n[ -s', path.read_text())
        self.assertNotIn('managed by old', path.read_text())
        first = path.read_bytes()
        MANAGED.update(path, 'nvm-load', 'echo new')
        self.assertEqual(first, path.read_bytes())

    @unittest.skipUnless(shutil.which('zsh'), 'requires zsh')
    def test_existing_omz_merges_plugins_before_loading_and_is_repeatable(self):
        self.stub('id', 'if [ "$1" = -u ]; then echo 0; else echo tester; fi')
        self.stub('getent', 'printf "tester:x:1000:1000::%s:/bin/bash\\n" "$HOME"')
        self.env['BOOTSTRAP_VENV'] = str(ROOT / '.venv')
        omz = self.home / '.oh-my-zsh'
        theme = omz / 'custom/themes/powerlevel10k'
        theme.mkdir(parents=True)
        (theme / 'powerlevel10k.zsh-theme').write_text('')
        (omz / 'oh-my-zsh.sh').write_text('print -r -- "loaded:${(j:,:)plugins}:$ZSH_THEME"\n')
        rc = self.home / '.zshrc'
        custom = ('export ZSH="$HOME/.oh-my-zsh"\n'
                  'plugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)\n'
                  '  source "${ZSH}/oh-my-zsh.sh"\n'
                  'export MY_CUSTOM_SETTING=keep\n')
        rc.write_text(custom)
        self.good(self.run_cmd(BASH, SCRIPTS / '02b-zsh.sh', '--default-shell', 'no'))
        before = rc.read_bytes()
        self.good(self.run_cmd(BASH, SCRIPTS / '02b-zsh.sh', '--default-shell', 'no'))
        self.assertEqual(before, rc.read_bytes())
        self.assertIn('plugins=(git docker zsh-autosuggestions zsh-syntax-highlighting)', rc.read_text())
        # Exercise zsh array operations and actual source order without Ubuntu apt plugins.
        probe = self.home / 'probe.zsh'
        probe.write_text('\n'.join(x for x in rc.read_text().splitlines() if not x.startswith('source /usr/share/')))
        result = self.good(self.run_cmd('zsh', '-c', 'source "$1"; print "$MY_CUSTOM_SETTING"', 'zsh', probe))
        self.assertIn('loaded:git,docker,sudo:powerlevel10k/powerlevel10k', result.stdout)
        self.assertIn('keep', result.stdout)

    @unittest.skipUnless(shutil.which('zsh'), 'requires zsh')
    def test_bun_available_in_noninteractive_zsh_without_wrapper(self):
        self.stub('bun', 'echo fixture-bun', self.home / '.bun/bin')
        self.good(self.run_cmd(BASH, SCRIPTS / '03a-bun.sh'))
        result = self.good(self.run_cmd('zsh', '-lc', 'bun --version; print "$BUN_INSTALL"'))
        self.assertIn('fixture-bun', result.stdout)
        self.assertIn(str(self.home / '.bun'), result.stdout)
        first = (self.home / '.zshenv').read_bytes()
        self.good(self.run_cmd(BASH, SCRIPTS / '03a-bun.sh'))
        self.assertEqual(first, (self.home / '.zshenv').read_bytes())

    def test_git_askpass_preserves_explicit_user_choice(self):
        for value in (None, '/user/askpass'):
            with self.subTest(value=value):
                if value is not None:
                    self.good(self.run_cmd('git', 'config', '--global', 'core.askPass', value))
                self.good(self.run_cmd(BASH, SCRIPTS / '05-git-identity.sh', '--name', 'Tester', '--email', 'test@example.invalid'))
                result = self.good(self.run_cmd('git', 'config', '--global', '--get', 'core.askPass'))
                self.assertEqual(result.stdout.strip(), value or '')

    def test_pinned_pnpm_uses_isolated_corepack_without_global_shims(self):
        source, target = self.repo({'package.json': '{"packageManager":"pnpm@10.2.0"}\n', 'pnpm-lock.yaml': 'lockfileVersion: 9.0\n'})
        self.stub('pnpm', 'echo 9.0.0')
        self.stub('npm', '''
printf 'npm:%s\\n' "$*" >> "$TRACE"
[ "$1 $2 $3" = 'install --global --prefix' ] || exit 8
mkdir -p "$4/bin"
cat > "$4/bin/corepack" <<'SH'
#!/bin/bash
printf 'corepack:%s:%s\\n' "$COREPACK_ENABLE_AUTO_PIN" "$*" >> "$TRACE"
[ "$2" != --version ] || echo 10.2.0
SH
chmod +x "$4/bin/corepack"
''')
        self.good(self.project(source, target))
        trace = (self.base / 'trace').read_text()
        self.assertIn('corepack:0:pnpm@10.2.0 install --frozen-lockfile', trace)
        self.assertNotIn('corepack enable', trace)
        self.assertEqual((target / 'package.json').read_text(), '{"packageManager":"pnpm@10.2.0"}\n')

    def test_missing_uv_installs_into_tool_venv_then_syncs_project(self):
        source, target = self.repo({'pyproject.toml': '[project]\nname="fixture"\nversion="0.1.0"\n'})
        self.stub('python3', '''
[ "$1 $2" = '-m venv' ] || exit 9
mkdir -p "$3/bin"
cat > "$3/bin/python" <<'SH'
#!/bin/bash
set -e
printf 'tool-python:%s\\n' "$*" >> "$TRACE"
if [ "$1 $2 $3" = '-m pip install' ]; then
 cat > "$(dirname "$0")/uv" <<'UV'
#!/bin/bash
printf 'uv:%s:%s\\n' "$UV_PROJECT_ENVIRONMENT" "$*" >> "$TRACE"
UV
 chmod +x "$(dirname "$0")/uv"
fi
SH
chmod +x "$3/bin/python"
''')
        self.good(self.project(source, target))
        trace = (self.base / 'trace').read_text()
        self.assertIn('tool-python:-m pip install uv', trace)
        self.assertIn(f'uv:{target}/.venv:sync\n', trace)

    def test_conflicting_lockfiles_stop_before_installation(self):
        source, target = self.repo({'package.json':'{"packageManager":"yarn@4.0.0"}', 'pnpm-lock.yaml':'lock'})
        self.assertNotEqual(self.project(source, target).returncode, 0)
        self.assertFalse((target / '.server-bootstrap-prepared').exists())
        self.assertFalse((self.base / 'trace').exists())


class Preflight(IsolatedCase):
    def fixture(self):
        scripts = self.base / 'scripts'
        shutil.copytree(SCRIPTS, scripts)
        os_release = self.base / 'os-release'
        os_release.write_text('ID=ubuntu\nVERSION_ID=26.04\n')
        proc = self.base / 'proc-status'
        proc.write_text('NoNewPrivs:\t0\n')
        script = scripts / '01-preflight.sh'
        script.write_text(script.read_text().replace('/etc/os-release', str(os_release)).replace('/proc/self/status', str(proc)))
        self.stub('id', 'if [ "$1" = -u ]; then echo 1000; else echo tester; fi')
        self.stub('systemctl', 'echo 260')
        self.stub('sudo', '[ "$*" = "-n id -u" ] || exit 9; echo 0')
        self.stub('curl', 'printf "%s\\n" "$*" >> "$TRACE"; exit 22')
        return script, proc

    def test_actual_sudo_check_and_network_warning_only_for_selected_features(self):
        script, _ = self.fixture()
        result = self.good(self.run_cmd(BASH, script, '--install-zsh', 'no'))
        self.assertIn('nvm: 未发现', result.stdout)
        self.assertFalse((self.base / 'trace').exists())
        result = self.good(self.run_cmd(BASH, script, '--install-zsh', 'no', '--install-node', 'yes', '--npm-registry', 'official'))
        self.assertIn('无法访问', result.stdout)
        self.assertIn('registry.npmjs.org', (self.base / 'trace').read_text())
        self.assertNotIn('npmmirror', (self.base / 'trace').read_text())

    def test_no_new_privileges_is_reported_without_false_host_failure(self):
        script, proc = self.fixture()
        self.stub('sudo', 'exit 1')
        proc.write_text('NoNewPrivs:\t1\n')
        result = self.run_cmd(BASH, script, '--install-zsh', 'no')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no new privileges', result.stdout)
