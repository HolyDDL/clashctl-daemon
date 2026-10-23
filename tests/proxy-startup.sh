#!/usr/bin/env bash
# Real socket conflicts and real Shell environments; kernel/service operations
# stay in a temporary installation and never touch the host service manager.
set -euo pipefail
REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TEST_YQ=${TEST_YQ:-$(command -v yq || true)}
export REPO_DIR TEST_YQ
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
from urllib.parse import quote

repo = Path(os.environ['REPO_DIR'])
yq = os.environ['TEST_YQ']
assert yq and Path(yq).is_file(), 'MikeFarah yq v4 is required'
for shell in ('bash', 'zsh', 'fish'):
    assert shutil.which(shell), f'{shell} is required'

with tempfile.TemporaryDirectory(prefix='clashctl-startup-') as work:
    home = Path(work) / 'install'
    shutil.copytree(repo / 'scripts', home / 'scripts')
    shutil.copytree(repo / 'resources', home / 'resources', ignore=shutil.ignore_patterns('*.dat', '*.mmdb'))
    (home / 'data').mkdir()
    (home / 'bin').mkdir()
    (home / '.env').write_text('CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n')
    (home / 'bin/yq').symlink_to(yq)
    (home / 'bin/mihomo').write_text('#!/bin/sh\nexit 0\n')
    (home / 'bin/mihomo').chmod(0o755)
    (home / 'scripts/lib/zz-test.sh').write_text('''
service_is_active() { [ -f "$CLASHCTL_HOME/running" ]; }
detect_service_manager() { service_manager=nohup; }
service_start() {
    [ ! -f "$CLASHCTL_HOME/fail-start" ] || return 1
    touch "$CLASHCTL_HOME/running"
}
service_stop() { command rm -f -- "$CLASHCTL_HOME/running"; }
service_stop_checked() { service_stop; }
service_enable() { :; }
_tun_is_active() { return 1; }
''')
    env = dict(os.environ, CLASHCTL_HOME=str(home), CLASHCTL_SRC=str(home),
               CLASHCTL_KERNEL='mihomo', CLASHCTL_COLOR='never', NO_COLOR='1',
               XDG_CACHE_HOME=str(home / 'cache'))
    runtime = home / 'data/runtime.yaml'
    mixin = home / 'data/mixin.yaml'
    last = home / 'data/last-proxy.yaml'

    def read_config(path):
        return json.loads(subprocess.check_output([yq, '-o=json', '.', str(path)], text=True))

    def configure(**values):
        config = {'mixed-port': 37700, 'external-controller': '127.0.0.1:0',
                  'allow-lan': False, 'tun': {'enable': False}}
        config.update(values)
        mixin.write_text(json.dumps(config))
        return config

    def run(code, shell='bash', expected=0, extra=None):
        source = 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; ' if shell == 'fish' else '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; '
        args = [shell, '--no-config' if shell == 'fish' else '-f' if shell == 'zsh' else '--noprofile']
        result = subprocess.run([*args, '-c', source + code], env=dict(env, **(extra or {})),
                                capture_output=True, text=True, timeout=20)
        assert result.returncode == expected, (shell, code, result.returncode, result.stdout, result.stderr)
        return result

    # Occupied previous/configured listener -> available dynamic high port.
    with socket.socket() as occupied:
        occupied.bind(('127.0.0.1', 0))
        occupied.listen()
        busy = occupied.getsockname()[1]
        configure(**{'mixed-port': busy})
        result = run('clashctl on')
        first = read_config(runtime)['mixed-port']
        assert 49152 <= first <= 65535 and first != busy, (busy, first)
        assert read_config(mixin)['mixed-port'] == first
        assert read_config(last)['mixed-port'] == first
        assert 'None (first start)' in result.stderr
        assert 'Port conflict' in result.stderr and 'Yes' in result.stderr
        assert f'{busy} -> {first}' in result.stderr
        assert '\x1b[' not in result.stderr

    # Fresh command process reuses the persisted selection when it is free.
    run('clashctl off --stop')
    result = run('clashctl on')
    assert read_config(runtime)['mixed-port'] == first
    assert f'http://127.0.0.1:{first}' in result.stderr
    assert 'Previous HTTP' in result.stderr and 'No' in result.stderr
    assert 'None (first start)' not in result.stderr

    # Repeated on must not mistake its own listener for somebody else's port.
    before = (mixin.read_bytes(), last.read_bytes())
    with socket.socket() as own_listener:
        own_listener.bind(('127.0.0.1', first))
        own_listener.listen()
        run('clashctl on')
        assert before == (mixin.read_bytes(), last.read_bytes())

    # Config-triggered restart checks the last listener after stopping the kernel.
    editor = home / 'editor'
    editor.write_text(f'#!/bin/sh\n"{yq}" -i \'.secret = "report-must-not-expose-this"\' "$1"\n')
    editor.chmod(0o755)
    with socket.socket() as occupied:
        occupied.bind(('127.0.0.1', first))
        occupied.listen()
        result = run('clashctl mixin -e', extra={'EDITOR': str(editor)})
    second = read_config(runtime)['mixed-port']
    assert 49152 <= second <= 65535 and second != first
    assert f'{first} -> {second}' in result.stderr
    assert 'report-must-not-expose-this' not in result.stderr

    # Port inspection errors and failed starts never claim a new successful port.
    run('clashctl off --stop')
    snapshot = last.read_bytes()
    result = run('_is_port_used() { return 2; }; http_proxy=http://before; '
                 'clashctl on; rc=$?; [ "$http_proxy" = http://before ] || exit 99; exit "$rc"', expected=1)
    assert 'Cannot inspect listening ports' in result.stderr
    assert not (home / 'running').exists() and last.read_bytes() == snapshot
    (home / 'fail-start').touch()
    run('clashctl on', expected=1)
    assert last.read_bytes() == snapshot
    (home / 'fail-start').unlink()

    # Disabled independent ports use the mixed listener; IPv6 and credentials
    # have exactly the same URI encoding in Bash, Zsh, Fish, and status.
    cases = [
        ({'mixed-port': 37700, 'port': 0, 'socks-port': 0}, '127.0.0.1', ''),
        ({'allow-lan': True, 'bind-address': '2001:db8::10'}, '[2001:db8::10]', ''),
        ({'allow-lan': True, 'bind-address': '::'}, '[::1]', ''),
        ({'allow-lan': True, 'bind-address': 'fe80::1%eth0'}, '[fe80::1%25eth0]', ''),
    ]
    for user, password in [('test', 'p@ss/#?word'), ('中 文', "a|b:c%'\\\n")]:
        cases.append(({'authentication': [f'{user}:{password}']}, '127.0.0.1',
                      f'{quote(user, safe="")}:{quote(password, safe="")}@'))
    for values, host, auth in cases:
        runtime.write_text(json.dumps(configure(**values)))
        (home / 'running').touch()
        for shell in ('bash', 'zsh', 'fish'):
            code = ('clashctl on >/dev/null; or exit; printf "%s\\n%s\\n" "$http_proxy" "$all_proxy"'
                    if shell == 'fish' else
                    'clashctl on >/dev/null || exit; printf "%s\\n%s\\n" "$http_proxy" "$all_proxy"')
            result = run(code, shell)
            assert result.stdout.splitlines() == [f'http://{auth}{host}:37700', f'socks5h://{auth}{host}:37700'], result.stdout
        result = run('_status_proxy_addresses; printf "%s\\n%s\\n" "$http_address" "$socks_address"')
        assert result.stdout.splitlines() == [f'http://{auth}{host}:37700', f'socks5h://{auth}{host}:37700']

    # Exercise the same standalone hook used by automatic systemd restarts.
    configure()
    (home / 'running').unlink()
    command = ['bash', str(home / 'scripts/kernel-start.sh'), 'prepare', str(home)]
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert 'Previous HTTP' in result.stderr and 'Current HTTP' in result.stderr
    subprocess.run(['bash', str(home / 'scripts/kernel-start.sh'), 'remember', str(home)], env=env, check=True)
    assert read_config(last)['mixed-port'] == read_config(runtime)['mixed-port']
    assert 'authentication' not in read_config(last)

    # Independent listeners and the controller cannot share a chosen port.
    configure(**{'mixed-port': 55500, 'port': 55500, 'socks-port': 55500,
                 'external-controller': '127.0.0.1:55500'})
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr
    config = read_config(runtime)
    ports = [config['mixed-port'], config['port'], config['socks-port']]
    assert len(set(ports)) == 3 and 55500 not in ports, config
    assert all(49152 <= port <= 65535 for port in ports), config

    # Controller conflicts preserve IPv6 hosts and commit only validated settings.
    configure(**{'external-controller': '[::1]:55501'})
    run('_merge_config')
    run('_is_port_used() { return 0; }; _get_random_port() { echo 55502; }; _detect_ext_addr')
    assert read_config(runtime)['external-controller'] == '[::1]:55502'
    assert read_config(mixin)['external-controller'] == '[::1]:55502'
    result = run('_node_api_base')
    assert result.stdout == 'http://[::1]:55502', result.stdout
    before = (mixin.read_bytes(), runtime.read_bytes())
    run('_is_port_used() { return 2; }; _detect_ext_addr', expected=1)
    assert before == (mixin.read_bytes(), runtime.read_bytes())
    run('_is_port_used() { return 0; }; _get_random_port() { echo 55503; }; '
        '_valid_config() { return 1; }; _detect_ext_addr', expected=1)
    assert before == (mixin.read_bytes(), runtime.read_bytes())

    # UI and upgrades must use the unified start path and stop on start failure.
    (home / 'resources/dist').mkdir(exist_ok=True)
    (home / 'resources/dist/index.html').touch()
    for cmd in ('ui', 'upgrade'):
        run('service_is_active() { return 1; }; clashstart() { return 42; }; '
            'service_start() { exit 99; }; curl() { exit 98; }; clashctl ' + cmd, expected=1)
    configure()

    # Forced color is available for terminals; normal redirected output is plain.
    color_env = dict(env, CLASHCTL_COLOR='always')
    color_env.pop('NO_COLOR', None)
    result = subprocess.run(command, env=color_env, text=True, capture_output=True, timeout=20)
    assert result.returncode == 0, result.stderr
    assert '\x1b[1;36m' in result.stderr and '\x1b[1;32m' in result.stderr, result.stderr

print('proxy-startup: ok')
PY
