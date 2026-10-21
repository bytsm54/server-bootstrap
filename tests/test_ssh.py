"""Exercise state transitions on real temp files; all OS commands are isolated doubles."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DRIVER = r'''
import os, sys, pathlib, hashlib, fcntl
p=pathlib.Path(os.environ['FIXTURE']); name=pathlib.Path(sys.argv[0]).name; a=sys.argv[1:]
def read(name, default=''):
    q=p/name
    return q.read_text() if q.exists() else default
def write(name, text): (p/name).write_text(text)
def dropin(): return p/'etc/ssh/sshd_config.d/00-server-bootstrap.conf'
def ports():
    if dropin().exists(): return [x.split()[1] for x in dropin().read_text().splitlines() if x.startswith('Port ')]
    return ['2222']
with (p/'trace').open('a') as f: f.write(name+' '+' '.join(a)+'\n')
if name=='id': print('0' if a==['-u'] else 'tester')
elif name=='flock': fcntl.flock(9, fcntl.LOCK_EX)
elif name=='getent': print('tester:x:1000:1000::'+str(p/'home/tester')+':/bin/bash')
elif name=='sleep': pass
elif name=='ss':
    if read('no-listeners'): sys.exit(0)
    for port in read('live','2222').split(','):
        if read('socket'):
            print('LISTEN 0 128 [::]:'+port+' [::]:* users:(("systemd",pid=1,fd=7))')
        else: print('LISTEN 0 128 0.0.0.0:'+port+' 0.0.0.0:* users:(("sshd",pid=111,fd=3))')
    print(read('extra'))
elif name=='systemctl':
    if a[0]=='is-active' and a[-1] in ('ssh.service','sshd.service') and read('inactive'): sys.exit(1)
    if a[0]=='is-active': sys.exit(0 if a[-1] not in ('ssh.socket','sshd.socket') or (a[-1]=='ssh.socket' and read('socket')) else 1)
    if a[0]=='show':
        if '--property=MainPID' in a: print('111' if a[1]=='ssh.service' and not read('inactive') else '0')
        elif '--property=KillMode' in a: print(read('kill-mode','process'))
        elif '--property=Requires' in a: print('ssh.socket')
        elif '--property=Listen' in a: print(' '.join('[::]:'+x+' (Stream)' for x in read('live','2222').split(',')))
    if a[0]=='reload' and a[1] in ('ssh','sshd','ssh.service','sshd.service') and not read('socket'): write('live',','.join(ports()))
    if a[0]=='restart' and a[1]=='ssh.socket':
        f=p/'etc/systemd/system/ssh.socket.d/99-server-bootstrap.conf'
        values=[x.rsplit(':',1)[-1] for x in f.read_text().splitlines() if x.startswith('ListenStream=') and x!='ListenStream='] if f.exists() else ['2222']
        write('live',','.join(values))
        if read('restart-fail') and f.exists():
            (p/'restart-fail').unlink(); sys.exit(1)
elif name=='sshd':
    if a[0]=='-t':
        if read('syntax-fail') and dropin().exists(): (p/'syntax-fail').unlink(); sys.exit(1)
    else:
        text=dropin().read_text() if dropin().exists() else 'Port 2222\nPermitRootLogin yes\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\nPubkeyAuthentication yes\nAllowUsers tester\n'
        if read('root-match') and 'user=root,' in ' '.join(a): text=text.replace('PermitRootLogin no','PermitRootLogin yes')
        for line in text.splitlines():
            if line and not line.startswith('#'):
                k,v=line.split(' ',1); print(k.lower(),v)
        print('authorizedkeysfile .ssh/authorized_keys')
elif name=='at':
    write('scheduled',sys.stdin.read())
    if read('at-fail'): sys.exit(1)
    print('job 42 at Wed Oct 21 00:00:00 2026')
elif name=='atrm':
    if read('atrm-fail'): sys.exit(1)
    write('cancelled','yes')
elif name=='sha256sum':
    if a[0]=='-c':
        for line in pathlib.Path(a[1]).read_text().splitlines():
            digest,path=line.split('  ',1)
            if hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()!=digest: sys.exit(1)
    else:
        for path in a: print(hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()+'  '+path)
elif name=='dpkg-query': print('install ok installed',end='')
elif name=='fail2ban-client':
    if read('f2b-fail'): sys.exit(1)
    # fail2ban 1.1 drops a newly introduced action on plain reload.
    if a==['reload']: write('f2b-action','missing')
    elif a==['reload','--restart','sshd']: write('f2b-action','ready')
    if a[:2]==['get','sshd']:
        if read('f2b-query-fail') or read('f2b-action')!='ready': sys.exit(1)
        f=p/'etc/fail2ban/jail.d/99-server-bootstrap.local'
        print(next(x.split('=',1)[1].strip() for x in f.read_text().splitlines() if x.startswith('port =')))
else: raise RuntimeError(name)
'''

class SSH(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bootstrap-ssh-')
        self.p = Path(self.temp.name)
        shutil.copytree(ROOT/'scripts',self.p/'scripts')
        # Rewrite filesystem roots only in the fixture; production scripts have fixed system paths.
        for script in (self.p/'scripts').rglob('*.sh'):
            source=re.sub(r'/(etc|var)/',lambda m: str(self.p)+m.group(),script.read_text())
            source=source.replace('-C / ', '-C "'+str(self.p)+'" ').replace('-C /;', '-C "'+str(self.p)+'";')
            source=source.replace('${socket_override#/}', '${socket_override#'+str(self.p)+'/}')
            script.write_text(source)
        for d in ('etc/ssh/sshd_config.d','var/run','home/tester/.ssh','bin','var/lib/server-bootstrap'):
            (self.p/d).mkdir(parents=True,exist_ok=True)
        self.original='Port 2222\n# user configuration\nPasswordAuthentication yes\n'
        (self.p/'etc/ssh/sshd_config').write_text(self.original)
        (self.p/'home/tester/.ssh/authorized_keys').write_text('a test public key\n')
        driver=self.p/'bin/driver';driver.write_text('#!'+sys.executable+'\n'+DRIVER);driver.chmod(0o755)
        for name in ('id','flock','getent','sleep','ss','systemctl','sshd','at','atrm','sha256sum','dpkg-query','fail2ban-client'):
            (self.p/'bin'/name).symlink_to(driver)
        self.env={**os.environ,'PATH':str(self.p/'bin')+':/usr/bin:/bin:/usr/sbin:/sbin','FIXTURE':str(self.p),'HOME':str(self.p/'home/tester')}
        self.env.pop('SSH_CONNECTION',None)
        self.record=self.p/'var/run/sshd-bootstrap-deadman.atjob'
    def tearDown(self): self.temp.cleanup()
    def run_script(self,*args,script='08-ssh-harden.sh',success=True):
        r=subprocess.run(['bash',str(self.p/'scripts'/script),*args],env=self.env,text=True,capture_output=True,timeout=20)
        if success: self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        else: self.assertNotEqual(r.returncode,0,r.stdout+r.stderr)
        return r
    def apply(self,port='',**kwargs): return self.run_script('apply','--port',port,'--allow-users','tester',**kwargs)
    def test_blank_port_and_confirm(self):
        self.apply(); self.assertIn('Port 2222',(self.p/'etc/ssh/sshd_config.d/00-server-bootstrap.conf').read_text())
        self.run_script('confirm'); self.assertFalse(self.record.exists())
        self.assertTrue((self.p/'var/lib/server-bootstrap/ssh-confirmed').exists())
    def test_current_port_is_not_a_collision(self): self.apply('2222')
    def test_invalid_ports_rejected_before_mutation(self):
        for port in ('0','65536','-1','2.2','abc'):
            self.apply(port,success=False)
            self.assertEqual((self.p/'etc/ssh/sshd_config').read_text(),self.original)
            self.assertFalse(self.record.exists())
    def test_other_process_and_reverse_tunnel_collision(self):
        for process in ('nginx","pid=900','sshd-session","pid=112','sshd","pid=112'):
            (self.p/'extra').write_text('LISTEN 0 10 0.0.0.0:8080 0.0.0.0:* users:(("'+process+'))')
            self.apply('8080',success=False)
            self.assertFalse(self.record.exists())
    def test_new_port_and_expiry_recovery_script(self):
        self.apply('65535'); self.assertEqual((self.p/'live').read_text(),'65535')
        # Execute exactly the frozen command handed to at, after removing the original code.
        shutil.rmtree(self.p/'scripts')
        r=subprocess.run(['bash','-c',(self.p/'scheduled').read_text()],env=self.env,text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        self.assertEqual((self.p/'live').read_text(),'2222');self.assertFalse(self.record.exists())
    def test_apply_failure_restores_files_and_listener(self):
        (self.p/'syntax-fail').write_text('1');self.apply('2200',success=False)
        self.assertEqual((self.p/'etc/ssh/sshd_config').read_text(),self.original)
        self.assertFalse(self.record.exists())
    def test_pending_apply_does_not_replace_baseline(self):
        self.apply('2200'); original=self.record.read_text()
        self.apply('2300',success=False);self.assertEqual(self.record.read_text(),original)
    def test_restore_missing_listener_keeps_recovery(self):
        self.apply('2200'); (self.p/'no-listeners').write_text('1')
        self.run_script('rollback',success=False);self.assertTrue(self.record.exists())
        self.assertFalse((self.p/'cancelled').exists())
    def test_failed_cancel_retains_ownership(self):
        self.apply('2200');(self.p/'atrm-fail').write_text('1')
        self.run_script('confirm',success=False);self.assertTrue(self.record.exists())
        self.run_script('rollback',success=False);self.assertIn('manual-restored',self.record.read_text())
        r=subprocess.run(['bash','-c',(self.p/'scheduled').read_text()],env=self.env,text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertFalse(self.record.exists())
    def test_confirmation_rechecks_listener(self):
        self.apply('2200');(self.p/'no-listeners').write_text('1')
        self.run_script('confirm',success=False);self.assertTrue(self.record.exists())
        self.assertFalse((self.p/'cancelled').exists())
    def test_expired_confirmation_rejected(self):
        self.apply('2200');rows=self.record.read_text().splitlines();rows[2]='1';self.record.write_text('\n'.join(rows)+'\n')
        self.run_script('confirm',success=False);self.assertTrue(self.record.exists())
    def test_scheduling_failure_does_not_modify_ssh(self):
        (self.p/'at-fail').write_text('1');self.apply('2200',success=False)
        self.assertEqual((self.p/'etc/ssh/sshd_config').read_text(),self.original)
    def test_root_match_override_rejected(self):
        (self.p/'root-match').write_text('1');self.apply('2200',success=False)
        self.assertEqual((self.p/'etc/ssh/sshd_config').read_text(),self.original)
    def test_socket_address_preserved_and_rollback(self):
        (self.p/'socket').write_text('1');self.apply('2200')
        override=self.p/'etc/systemd/system/ssh.socket.d/99-server-bootstrap.conf'
        self.assertIn('ListenStream=[::]:2200',override.read_text())
        self.run_script('rollback');self.assertFalse(override.exists());self.assertEqual((self.p/'live').read_text(),'2222')
    def test_socket_on_demand_state_is_supported(self):
        (self.p/'socket').write_text('1');(self.p/'inactive').write_text('1')
        self.apply('2200');self.run_script('rollback')
        self.assertEqual((self.p/'live').read_text(),'2222')
    def test_unsafe_socket_kill_mode_rejected_before_mutation(self):
        (self.p/'socket').write_text('1');(self.p/'kill-mode').write_text('control-group')
        self.apply('2200',success=False);self.assertFalse(self.record.exists())
        self.assertEqual((self.p/'etc/ssh/sshd_config').read_text(),self.original)
    def test_failed_socket_restart_restores_listener(self):
        (self.p/'socket').write_text('1');(self.p/'restart-fail').write_text('1')
        self.apply('2200',success=False);self.assertEqual((self.p/'live').read_text(),'2222');self.assertFalse(self.record.exists())
    def test_fail2ban_uses_confirmed_ports_and_refuses_pending(self):
        self.apply('2200');self.run_script(script='09-fail2ban.sh',success=False)
        self.run_script('confirm');self.run_script(script='09-fail2ban.sh')
        self.assertIn('port = 2200',(self.p/'etc/fail2ban/jail.d/99-server-bootstrap.local').read_text())
    def test_fail2ban_query_failure_restores_existing_config_once(self):
        jail=self.p/'etc/fail2ban/jail.d/99-server-bootstrap.local'
        jail.parent.mkdir(parents=True)
        jail.write_text('existing configuration\n')
        (self.p/'f2b-query-fail').write_text('1')
        result=self.run_script(script='09-fail2ban.sh',success=False)
        self.assertEqual(jail.read_text(),'existing configuration\n')
        self.assertEqual(result.stderr.count('已恢复先前配置'),1)
        self.assertNotIn('cannot stat',result.stderr)

if __name__=='__main__': unittest.main()
