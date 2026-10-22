"""Merge owned jail settings and inspect fail2ban's literal command dump (no eval).

Run in the helper venv; privileged reads/commands are performed by the caller.
"""
import argparse
import ast
import json
import re
import subprocess
import sys

OWNED = {'enabled', 'backend', 'port', 'maxretry', 'findtime', 'bantime'}
GENERATED_ACTION = 'iptables-multiport[name=sshd, port="%(port)s", protocol=tcp]'


def strip_owned(text, remove_generated_action=False):
    section = ''
    result = []
    skipping = False
    for line in text.splitlines(keepends=True):
        header = re.match(r'\s*\[([^]]+)\]', line)
        if header:
            section = header[1].lower()
            skipping = False
        option = re.match(r'\s*([\w.]+)\s*=\s*(.*?)\s*$', line)
        if section == 'sshd' and option:
            skipping = option[1].lower() in OWNED or (
                remove_generated_action and option[1].lower() == 'action' and option[2] == GENERATED_ACTION)
            if skipping:
                continue
        elif skipping and line[:1].isspace() and line.strip() and not line.lstrip().startswith(('#', ';')):
            continue
        else:
            skipping = False
        result.append(line)
    return ''.join(result)


def merge(text, ports, retry, find, ban):
    # Preserve unrelated sections/options, including custom action/banaction.
    text = strip_owned(text, text.startswith('# Managed by server-bootstrap\n'))
    body = f'enabled = true\nbackend = systemd\nport = {ports}\nmaxretry = {retry}\nfindtime = {find}\nbantime = {ban}\n'
    header = re.search(r'^[ \t]*\[sshd\][ \t]*(?:[#;][^\n]*)?$', text, re.M | re.I)
    if header:
        position = header.end()
        return text[:position] + '\n' + body.rstrip('\n') + text[position:]
    return text.rstrip('\n') + ('\n' if text else '# Managed by server-bootstrap\n') + '[sshd]\n' + body


def plan(stream):
    result = {'actions': {}, 'settings': {}}
    for line in stream:
        if not line.startswith('['):
            continue
        command = ast.literal_eval(line)
        if len(command) < 3 or command[1] != 'sshd':
            continue
        if command[0] == 'set' and command[2] in ('maxretry', 'findtime', 'bantime'):
            result['settings'][command[2]] = str(command[3])
        elif command[0] == 'set' and command[2] == 'addaction':
            result['actions'].setdefault(command[3], {})
        elif command[:3] == ['multi-set', 'sshd', 'action']:
            result['actions'].setdefault(command[3], {}).update(command[4])
        elif command[:3] == ['set', 'sshd', 'action']:
            result['actions'].setdefault(command[3], {})[command[4]] = command[5]
    if not result['actions'] or len(result['settings']) != 3:
        raise ValueError('无法解析 sshd jail 的动作和参数')
    return result


def packages(data):
    text = json.dumps(data['actions'])
    mapping = {'iptables': 'iptables', 'nftables': 'nftables', 'firewallcmd': 'firewalld', 'ufw': 'ufw', 'ipset': 'ipset'}
    return sorted({package for key, package in mapping.items() if key in text})


def normalize_ports(value):
    return ','.join(str(p) for p in sorted({int(x.strip()) for x in str(value).split(',')}))


def check(data, ports, sudo=False):
    prefix = ['sudo', '-n'] if sudo else []
    def get(*args):
        return subprocess.check_output(prefix + ['fail2ban-client', 'get', 'sshd', *args], text=True, stderr=subprocess.PIPE).strip()
    for key, value in data['settings'].items():
        if get(key) != value:
            raise ValueError(f'运行中的 {key} 与配置不一致')
    # Exact action set, not only an old action with the right port.
    actual = get('actions').splitlines()
    if actual and actual[0].startswith('The jail '):
        actual = actual[1:]
    if set(x.strip() for x in actual if x.strip()) != set(data['actions']):
        raise ValueError('运行中的 action 集合与配置不一致')
    protected = False
    for action, props in data['actions'].items():
        commands = '\n'.join(str(props.get(key, '')) for key in ('actionstart', 'actionban'))
        firewall = bool(re.search(r'\b(?:ip6?tables|iptables|nftables|nft|firewall-cmd|ufw|ipset|shorewall)\b', commands))
        if 'port' in props:
            if normalize_ports(props['port']) != ports or normalize_ports(get('action', action, 'port')) != ports:
                raise ValueError(f'{action} 的端口与实际 SSH 监听不一致')
            # A notification-only action cannot count as network protection.
            if firewall and props.get('actionban'):
                protected = True
        elif firewall and props.get('actionban') and ('allports' in action or action == 'ufw'):
            protected = True
        # Query all commands that establish/remove a ban, including stale actions
        # with the right name/port but different rules.
        for key in ('actionstart', 'actionban', 'actionunban', 'actioncheck'):
            if key in props and get('action', action, key) != str(props[key]).strip():
                raise ValueError(f'{action} 运行中的 {key} 与配置不一致')
    if not protected:
        raise ValueError('未能验证 SSH 的封禁动作；请检查自定义 action 是否覆盖实际端口')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['merge', 'legacy', 'plan', 'packages', 'expected', 'check'])
    parser.add_argument('--ports')
    parser.add_argument('--retry', default='5')
    parser.add_argument('--find', default='600')
    parser.add_argument('--ban', default='3600')
    parser.add_argument('--sudo', action='store_true')
    args = parser.parse_args()
    if args.mode == 'merge':
        sys.stdout.write(merge(sys.stdin.read(), args.ports, args.retry, args.find, args.ban))
    elif args.mode == 'legacy':
        sys.stdout.write(strip_owned(sys.stdin.read()))
    elif args.mode == 'plan':
        print(json.dumps(plan(sys.stdin)))
    elif args.mode == 'expected':
        data = json.load(sys.stdin)
        expected = {'maxretry': args.retry, 'findtime': args.find, 'bantime': args.ban}
        if data['settings'] != expected:
            raise ValueError('其他 fail2ban 文件覆盖了请求的 jail 参数，请处理配置冲突')
    elif args.mode == 'packages':
        print('\n'.join(packages(json.load(sys.stdin))))
    else:
        check(json.load(sys.stdin), normalize_ports(args.ports), args.sudo)
