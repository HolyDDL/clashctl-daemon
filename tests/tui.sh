#!/usr/bin/env bash
set -euo pipefail
export REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
export TEST_YQ=${TEST_YQ:-$(command -v yq || true)}
python3 - <<'PY'
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time

repo = Path(os.environ['REPO_DIR'])
yq = os.environ['TEST_YQ']
assert yq and Path(yq).is_file(), 'MikeFarah yq v4 is required'
with tempfile.TemporaryDirectory(prefix='clashctl-tui-') as work:
    home = Path(work)
    shutil.copytree(repo / 'scripts', home / 'scripts')
    (home / 'data').mkdir()
    (home / 'bin').mkdir()
    (home / 'resources').mkdir()
    (home / 'bin/yq').symlink_to(yq)
    (home / 'bin/mihomo').write_text('#!/bin/sh\nexit 0\n')
    (home / 'bin/mihomo').chmod(0o755)
    (home / '.env').write_text('CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n')
    (home / 'scripts/lib/zz-fixture.sh').write_text('''
detect_service_manager() { service_manager=systemd-user; }
service_state() { if [ -f "$CLASHCTL_HOME/running" ]; then echo running; else echo stopped; fi; }
service_is_active() { [ -f "$CLASHCTL_HOME/running" ]; }
service_start() { echo start >>"$CLASHCTL_HOME/actions"; touch "$CLASHCTL_HOME/running"; }
service_stop() { echo stop >>"$CLASHCTL_HOME/actions"; command rm -f "$CLASHCTL_HOME/running"; }
service_enable() { echo enable >>"$CLASHCTL_HOME/actions"; }
service_disable() { echo disable >>"$CLASHCTL_HOME/actions"; }
systemctl() { [ "$2" = is-enabled ] && { echo disabled; return 1; }; return 99; }
_kernel_start() { service_start; }
tunstatus() { return 1; }
''')
    (home / 'scripts/cmd/zz-fixture.sh').write_text('clashsub() {\n    printf \'sub:%s\\n\' "$*" >>"$CLASHCTL_HOME/actions"\n    echo \'Subscription operation complete (fixture).\'\n}\n')
    env = dict(os.environ, CLASHCTL_HOME=str(home), CLASHCTL_SRC=str(home),
               TERM='xterm-256color', NO_COLOR='1')
    config = {'mixed-port': 37700, 'allow-lan': False, 'mode': 'direct',
              'external-controller': '127.0.0.1:9090', 'tun': {'enable': False}}
    mixin = home / 'data/mixin.yaml'
    runtime = home / 'data/runtime.yaml'
    mixin.write_text(json.dumps(config))
    source = '. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh"; '

    def run(code, expected=0):
        result = subprocess.run(['bash', '-c', source + code], env=env,
                                text=True, capture_output=True, timeout=15)
        assert result.returncode == expected, (code, result.returncode, result.stdout, result.stderr)
        return result

    def read(path):
        return json.loads(subprocess.check_output([yq, '-o=json', '.', str(path)], text=True))

    run('_merge_config')
    run('clashctl tui --help')
    run('clashctl tui', expected=1)
    run('_tui_set mixed-port 40123')
    assert read(mixin)['mixed-port'] == read(runtime)['mixed-port'] == 40123
    assert not (home / 'running').exists() and not (home / 'actions').exists()
    before = (mixin.read_bytes(), runtime.read_bytes())
    for key, value in [('mixed-port', '0'), ('port', '65536'), ('port', 'abc'),
                       ('mode', 'evil'), ('external-controller', 'localhost:0')]:
        run(f'_tui_set {key} {value}', expected=1)
        assert before == (mixin.read_bytes(), runtime.read_bytes())
    run('_valid_config() { return 1; }; _tui_set mixed-port 40124', expected=1)
    assert before == (mixin.read_bytes(), runtime.read_bytes())
    assert not (home / 'data/startup.lock.d').exists()
    run('_tui_set secret true; _tui_set external-controller "[::1]:9091"')
    assert read(mixin)['secret'] == 'true'
    assert read(mixin)['external-controller'] == '[::1]:9091'
    (home / 'running').touch()
    run('_tui_set mode rule')
    assert read(runtime)['mode'] == 'rule'
    assert (home / 'actions').read_text().splitlines() == ['stop', 'start']
    run('_tui_startup disable; _tui_startup enable')
    assert (home / 'actions').read_text().splitlines()[-2:] == ['disable', 'enable']
    run('service_start() { return 1; }; _tui_set mode direct', expected=1)
    assert read(mixin)['mode'] == 'direct'
    run('service_state() { return 1; }; _tui_set mode rule', expected=1)
    assert read(mixin)['mode'] == 'direct'
    (home / 'actions').unlink()

    # Drive the real UI through a PTY. Verify keyboard navigation, saved ports,
    # start/stop dispatch, normal exit and signal cleanup without host services.
    def session(shell='bash', interrupt=False):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 35, 110, 0, 0))
        original = termios.tcgetattr(slave)
        if shell == 'fish':
            command = ['fish', '--no-config', '-c', 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.fish"; clashctl tui']
        else:
            command = [shell, '-f' if shell == 'zsh' else '--noprofile', '-c', source + 'clashctl tui']
        process = subprocess.Popen(command, env=env, stdin=slave, stdout=slave, stderr=slave,
                                   start_new_session=True)
        output = b''
        transcript = b''
        def expect(token):
            nonlocal output, transcript
            token = token.encode()
            deadline = time.monotonic() + 15
            while token not in output:
                assert time.monotonic() < deadline, (token, output[-1500:])
                ready, _, _ = select.select([master], [], [], 0.1)
                if ready:
                    try: chunk = os.read(master, 65536)
                    except OSError as e:
                        if e.errno == errno.EIO: chunk = b''
                        else: raise
                    assert chunk, (token, process.poll(), output[-1500:])
                    output += chunk
                    transcript += chunk
            output = output.split(token, 1)[1]
        def send(keys): os.write(master, keys.encode())
        try:
            expect('Number keys select immediately.')
            if interrupt:
                os.killpg(process.pid, signal.SIGTERM)
            elif shell == 'bash':
                send('4')
                expect('Proxy ports')
                expect('Number keys select immediately.')
                send('\r')
                expect('empty cancels')
                send('40125\n')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('q')
                expect('Number keys select immediately.')
                send('\x1b[B')
                expect('> 2  Subscriptions')
                send('\x1b[A')
                expect('> 1  Kernel & startup')
                send('\r')
                expect('Number keys select immediately.')
                send('1')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('2')
                expect('[y/N]')
                send('y\n')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('q')
                expect('Number keys select immediately.')
                send('2')
                expect('Add & activate subscription')
                expect('Number keys select immediately.')
                send('2')
                expect('empty cancels')
                send('https://example.invalid/private-token\n')
                expect('Press any key to return')
                assert b'private-token' not in transcript, 'secret input was echoed'
                send('x')
                expect('Number keys select immediately.')
                send('3')
                expect('Subscription operation complete (fixture).')
                expect('Press any key to return')
                send('x')
                expect('Number keys select immediately.')
                send('qq')
            else:
                send('q')
            rc = process.wait(timeout=10)
            assert rc in ((143, -signal.SIGTERM) if interrupt else (0,)), rc
            # The forwarding shell can exit before the UI child finishes its trap.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if not select.select([master], [], [], 0.1)[0]:
                    if b'\x1b[?1049l' in output: break
                    continue
                try: chunk = os.read(master, 65536)
                except OSError: break
                if not chunk: break
                output += chunk
            assert b'\x1b[?1049l' in output, output[-1000:]
            assert termios.tcgetattr(slave) == original, 'terminal mode was not restored'
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            os.close(master)
            os.close(slave)
    session()
    assert read(mixin)['mixed-port'] == 40125
    actions = (home / 'actions').read_text()
    assert 'start' in actions
    assert 'sub:add --use https://example.invalid/private-token' in actions
    assert 'sub:use' in actions
    assert not (home / 'running').exists()
    for shell in ('zsh', 'fish'):
        assert shutil.which(shell), f'{shell} is required'
        session(shell)
    session(interrupt=True)
print('tui: ok')
PY
