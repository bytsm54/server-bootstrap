"""Orchestration, hostname and package changes with isolated command doubles."""
import os
from pathlib import Path
import shutil
import sys
import unittest
from test_basics import IsolatedCase, SCRIPTS, BASH

class Stages(IsolatedCase):
    def setUp(self):
        super().setUp()
        self.stub('id','if [ "$1" = -u ]; then echo 0; else echo tester; fi')
        self.stub('systemctl','case "$*" in *MainPID*) echo 111 ;; *is-active*) exit 1 ;; esac')
        self.stub('ss','echo \'LISTEN 0 10 0.0.0.0:3333 0.0.0.0:* users:(("sshd",pid=111,fd=3))\'')
        self.env['SERVER_INIT_INTERACTIVE']='yes'
        self.phases=self.base/'phases/scripts';self.phases.mkdir(parents=True)
        self.env['REPO_DIR']=str(self.phases.parent)
        for name in ['01-preflight.sh','02-base-deps.sh','02a-system.sh','02b-zsh.sh','03-node.sh','03a-bun.sh','05-git-identity.sh','08-ssh-harden.sh','09-fail2ban.sh','verify-server.sh']:
            self.stub(name, '''name="$(basename "$0")"
printf '%s' "$name" >> "$TRACE"; printf ' <%s>' "$@" >> "$TRACE"; printf '\\n' >> "$TRACE"
[ "${FAIL_PHASE:-}" != "$name" ] || exit 13
if [ "${1:-}" = deadline ]; then echo "$DEADLINE"; fi''',directory=self.phases)
        self.env['DEADLINE']='2000000300'
        self.stub('date','if [ "$1" = +%s ]; then echo 2000000000; else /bin/date "$@"; fi')
    def init(self,*args,input=None):
        return self.run_cmd(BASH,SCRIPTS/'server-init.sh','--yes','--git-name','Tester','--git-email','test@example.invalid','--ssh-allow-users','tester',*args,input=input)
    def trace(self): return (self.base/'trace').read_text()
    def test_prepare_skips_security_and_optional_runtimes(self):
        self.good(self.init('--stage','prepare'))
        trace=self.trace()
        for phase in ('08-ssh','09-fail','03-node','03a-bun'): self.assertNotIn(phase,trace)
        self.assertIn('02b-zsh.sh <--theme> <powerlevel10k/powerlevel10k>',trace)
        self.assertIn('<--install-zsh> <yes> <--zsh-theme> <powerlevel10k/powerlevel10k>',trace)
        self.assertIn('02a-system.sh <--hostname> <>',trace)
        self.assertIn('<--harden-ssh> <no>',trace)
    def test_explicit_zsh_skip_does_not_run_phase(self):
        self.good(self.init('--stage','prepare','--install-zsh','no'))
        self.assertNotIn('02b-zsh',self.trace())
        self.assertIn('<--install-zsh> <no>',self.trace())
    def test_interactive_zsh_defaults_and_theme_override(self):
        for theme in ('', 'robbyrussell'):
            with self.subTest(theme=theme):
                (self.base/'trace').write_text('')
                self.good(self.run_cmd(BASH,SCRIPTS/'server-init.sh','--stage','prepare',
                    '--hostname','','--timezone','','--install-node','no','--install-bun','no',
                    '--git-name','Tester','--git-email','test@example.invalid',
                    '--harden-ssh','no','--enable-fail2ban','no',input='\n'+theme+'\nyes\n'))
                self.assertIn(f'02b-zsh.sh <--theme> <{theme or "powerlevel10k/powerlevel10k"}>',self.trace())
    def test_interactive_node_version_and_security_overrides_reach_phases(self):
        self.good(self.run_cmd(BASH,SCRIPTS/'server-init.sh',
            '--hostname','','--timezone','','--install-node','yes','--install-bun','no',
            '--install-zsh','no','--git-name','Tester','--git-email','test@example.invalid',
            '--harden-ssh','yes','--ssh-port','22022','--ssh-allow-users','tester',
            '--enable-fail2ban','yes', input='24\nofficial\nno\nno\n8\nyes\n已准备\n成功\n'))
        trace=self.trace()
        self.assertIn('03-node.sh <--node-version> <24> <--npm-registry> <official>',trace)
        self.assertIn('<--permit-root> <no> <--password-auth> <no> <--rollback-after-minutes> <8>',trace)
    def test_new_connection_confirmation_and_actual_port_handoff(self):
        for args,port in [((), '22022'), (('--ssh-port','4444'), '4444'), (('--ssh-port',''), '')]:
            with self.subTest(args=args):
                (self.base/'trace').write_text('')
                self.good(self.init(*args,input='已准备\n成功\n'))
                trace=self.trace();self.assertIn('08-ssh-harden.sh <confirm>',trace)
                self.assertIn(f'08-ssh-harden.sh <apply> <--port> <{port}>',trace)
                self.assertIn('09-fail2ban.sh <>',trace); self.assertNotIn('09-fail2ban.sh <--ssh-port>',trace)
    def test_interactive_port_default_custom_and_keep(self):
        for answer,port in [('', '22022'), ('4444', '4444'), ('keep', '')]:
            with self.subTest(answer=answer):
                (self.base/'trace').write_text('')
                self.good(self.run_cmd(BASH,SCRIPTS/'server-init.sh',
                    '--hostname','','--timezone','','--install-node','no','--install-bun','no',
                    '--install-zsh','no','--git-name','Tester','--git-email','test@example.invalid',
                    '--harden-ssh','yes','--ssh-allow-users','tester','--enable-fail2ban','yes',
                    input=answer+'\n\n\n\nyes\n已准备\n成功\n'))
                self.assertIn(f'08-ssh-harden.sh <apply> <--port> <{port}>',self.trace())
    def test_timeout_or_failed_connection_rolls_back_and_returns_failure(self):
        for deadline,answer in [('2000000010','成功'),('2000000300','失败')]:
            self.env['DEADLINE']=deadline
            (self.base/'trace').write_text('')
            result=self.init(input='已准备\n'+answer+'\n')
            self.assertNotEqual(result.returncode,0,result.stdout)
            self.assertIn('08-ssh-harden.sh <rollback>',self.trace())
            self.assertNotIn('08-ssh-harden.sh <confirm>',self.trace())
    def test_dependency_failure_stops_later_mutations(self):
        self.env['FAIL_PHASE']='02-base-deps.sh'
        result=self.init('--stage','prepare');self.assertNotEqual(result.returncode,0)
        self.assertNotIn('02a-system.sh',self.trace());self.assertNotIn('verify-server',self.trace())
    def test_root_only_gets_account_guidance_before_phases(self):
        result=self.init('--ssh-allow-users','root','--stage','prepare')
        self.assertNotEqual(result.returncode,0);self.assertIn('adduser',result.stdout)
        self.assertFalse((self.base/'trace').exists())

class System(IsolatedCase):
    def test_blank_system_options_do_not_mutate(self):
        self.good(self.run_cmd(BASH,SCRIPTS/'02a-system.sh','--hostname','','--timezone',''))
        self.assertFalse((self.base/'trace').exists())
    def test_hostname_updates_hosts_atomically_preserving_alias(self):
        scripts=self.base/'scripts';shutil.copytree(SCRIPTS,scripts)
        hosts=self.base/'hosts';hosts.write_text('127.0.0.1 localhost\n127.0.1.1 old alias # note\n')
        path=scripts/'02a-system.sh';path.write_text(path.read_text().replace('/etc/hosts',str(hosts)))
        self.stub('id','echo 0')
        self.stub('hostnamectl','if [ "$1" = --static ]; then echo old; else printf "%s\\n" "$*" >> "$TRACE"; fi')
        self.good(self.run_cmd(BASH,path,'--hostname','new-name','--timezone',''))
        self.assertIn('127.0.1.1 new-name alias # note',hosts.read_text())
        self.assertIn('127.0.1.1 old alias',Path(str(hosts)+'.server-bootstrap.bak').read_text())
    def test_base_dependencies_install_venv_without_system_pip(self):
        self.stub('id','echo 0')
        self.stub('dpkg-query','[ -f "$HOME/installed" ] && printf "install ok installed"')
        self.stub('apt-get','printf "%s\\n" "$*" >> "$TRACE"; if [ "$1" = install ]; then touch "$HOME/installed"; fi')
        self.env['BOOTSTRAP_VENV']=str(self.home/'runtime')
        self.stub('python3','''[ "$1 $2" = "-m venv" ] || exit 99
printf 'python3 %s\\n' "$*" >> "$TRACE"
mkdir -p "$3/bin"; printf '#!/bin/sh\\nexit 0\\n' > "$3/bin/python"; chmod +x "$3/bin/python"''')
        self.good(self.run_cmd(BASH,SCRIPTS/'02-base-deps.sh','--with-ssh','yes'))
        trace=(self.base/'trace').read_text();self.assertIn('python3-venv',trace);self.assertIn('iproute2 at util-linux',trace)
        self.assertIn('python3 -m venv',trace);self.assertNotIn('pip install',trace)
        (self.base/'trace').write_text('')
        self.good(self.run_cmd(BASH,SCRIPTS/'02-base-deps.sh','--with-ssh','yes'))
        self.assertEqual((self.base/'trace').read_text(),'')

if __name__=='__main__': unittest.main()
