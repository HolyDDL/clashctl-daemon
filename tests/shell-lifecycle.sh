#!/usr/bin/env bash
# Real loaders and uninstaller in isolated installations; never touch host services.
set -euo pipefail
export REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 - <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(os.environ['REPO_DIR'])
with tempfile.TemporaryDirectory(prefix='clashctl-lifecycle-') as work:
    root = Path(work)
    user = root / 'user'
    user.mkdir()
    variables = ['http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY',
                 'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY', 'CLASHCTL_HOME']
    for shell in ('bash', 'zsh', 'fish'):
        assert shutil.which(shell), f'{shell} is required'
        for scenario in ('success', 'cancel', 'failure', 'help'):
            home = root / f'{shell}-{scenario}'
            shutil.copytree(repo / 'scripts', home / 'scripts')
            shutil.copy(repo / 'uninstall.sh', home / 'uninstall.sh')
            shutil.copy(repo / 'install.sh', home / 'install.sh')
            (home / 'data').mkdir()
            (home / '.env').write_text('CLASHCTL_KERNEL=mihomo\nINIT_TYPE=nohup\n')
            (home / '.clashctl-install').write_text(f'{home}\narchive\n')
            (home / 'scripts/preflight.sh').write_text('''
. "$CLASHCTL_HOME/.env"
. "$CLASHCTL_HOME/scripts/lib/common.sh"
uninstall_service() { [ "${FAIL_REMOVE:-0}" != 1 ]; }
revoke_rc() { :; }
''')
            env = dict(os.environ, HOME=str(user), XDG_CACHE_HOME=str(user / 'cache'),
                       CLASHCTL_HOME=str(home), CLASHCTL_SRC=str(home),
                       FAIL_REMOVE='1' if scenario == 'failure' else '0', TERM='dumb', NO_COLOR='1')
            env.update({key: 'before-' + key for key in variables if key != 'CLASHCTL_HOME'})
            # Execute exactly the activation line emitted by the real installer.
            footer = subprocess.run(['bash', '-c', '''
. "$CLASHCTL_HOME/scripts/cmd/clashctl.sh" || exit
. "$1/install.sh"
service_is_active() { return 1; }
service_manager=nohup
_install_next_step "$2"
''', '--', str(repo), shell], env=env, text=True, capture_output=True, check=True)
            activation = next(line.strip().split('  # ', 1)[0] for line in footer.stderr.splitlines()
                              if line.lstrip().startswith('set -gx CLASHCTL_HOME' if shell == 'fish' else 'export CLASHCTL_HOME='))
            assert 'source "$CLASHCTL_HOME/scripts/cmd/clashctl.' in activation
            args = '--help' if scenario == 'help' else '' if scenario == 'cancel' else '--yes'
            after = 'printf "AFTER|' + '|'.join(['%s'] * len(variables)) + '\\n" ' + ' '.join('"$' + v + '"' for v in variables)
            if shell == 'fish':
                code = activation + '; clashctl uninstall ' + args + '; set -l rc $status; ' + after + '; if functions -q clashctl; echo COMMAND-PRESENT; else; echo COMMAND-CLEARED; end; exit $rc'
                command = ['fish', '--no-config', '-c', code]
            else:
                code = activation + '; clashctl uninstall ' + args + '; rc=$?; ' + after + '; if typeset -f clashctl >/dev/null; then echo COMMAND-PRESENT; else echo COMMAND-CLEARED; fi; exit "$rc"'
                command = [shell, '-f' if shell == 'zsh' else '--noprofile', '-c', code]
            result = subprocess.run(command, env=env, input='n\n' if scenario == 'cancel' else '',
                                    text=True, capture_output=True, timeout=20)
            expected_rc = 0 if scenario in ('success', 'help') else 1
            assert result.returncode == expected_rc, (shell, scenario, result.stdout, result.stderr)
            if scenario == 'success':
                assert not home.exists()
                expected = [''] * len(variables)
                assert 'COMMAND-CLEARED' in result.stdout
                assert '清除当前终端代理（' not in result.stdout, 'wrapper requested redundant manual cleanup'
            else:
                assert home.exists()
                expected = ['before-' + key if key != 'CLASHCTL_HOME' else str(home) for key in variables]
                assert 'COMMAND-PRESENT' in result.stdout
            assert 'AFTER|' + '|'.join(expected) in result.stdout, (shell, scenario, result.stdout, result.stderr)
print('shell-lifecycle: ok')
PY
