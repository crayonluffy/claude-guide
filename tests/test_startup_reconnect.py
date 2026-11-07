"""A live shared owner can temporarily have no listeners while SSH reconnects."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ.get('PROXY_READINESS_SOURCE',
              str(Path(__file__).resolve().parents[1] / 'scripts/claude-proxy.sh')))


class ReconnectStartupTests(unittest.TestCase):
    def test_new_claude_and_codex_windows_wait_for_the_live_owner(self):
        for shell in ('bash', 'zsh'):
            if not shutil.which(shell):
                continue
            for provider in ('claude', 'codex'):
                with self.subTest(shell=shell, provider=provider), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    conf = root / 'proxy.conf'
                    conf.write_text('CLAUDE_SYNC_SETTINGS=0\nCLAUDE_PROXY_BANNER=0\n'
                                    'CLAUDE_HTTP_PORT=18080\nCLAUDE_SOCKS_PORT=11080\n'
                                    'CLAUDE_WATCHDOG_STARTUP_GRACE=3\n')
                    slot = root / 'state/claude-proxy/recovery/main'
                    (slot / 'lock').mkdir(parents=True)
                    pid = os.getpid()
                    proc = Path(f'/proc/{pid}/stat')
                    stamp = (proc.read_text().rsplit(') ', 1)[1].split()[19] if proc.exists()
                             else subprocess.check_output(['ps', '-p', str(pid), '-o', 'lstart='],
                                  env={**os.environ, 'LC_ALL': 'C'}, text=True).strip())
                    owner = f'{pid}\n{stamp}\n'
                    (slot / 'lock/owner').write_text(owner)
                    (slot / 'tunnel.rec').write_text('host=test-node\nuser=\nport=22\nkey=\n'
                                                   'http=18080\nsocks=11080\nremote=8888\n')
                    probes = root / 'probes'
                    ready = root / 'ready'
                    code = ('_tunnel_health() { if [ -f ' + shlex.quote(str(ready)) + ' ]; then echo "ok 123 ssh 18080"; else echo down; fi; }; '
                            '_recovery_probe() { echo probe >> ' + shlex.quote(str(probes)) + '; '
                            'if [ "$(wc -l < ' + shlex.quote(str(probes)) + ')" -ge 2 ]; then touch ' + shlex.quote(str(ready)) + '; echo "healthy|0|200|404|healthy"; '
                            'else echo "tunnel|7|000|000|tunnel"; fi; }; '
                            '_killswitch_check() { :; }; sleep() { :; }; proxy-up --no-verify')
                    env = {k: v for k, v in os.environ.items()
                           if not k.startswith(('CLAUDE_', '_CLAUDE_'))}
                    env.update(CLAUDE_PROXY_CONF=str(conf), CLAUDE_PROXY_NODES=str(root / 'nodes.json'),
                               CLAUDE_SETTINGS=str(root / 'settings.json'), XDG_STATE_HOME=str(root / 'state'),
                               CLAUDE_TUNNEL_LOG=str(root / 'tunnel.log'), _CLAUDE_LAUNCH_PROVIDER=provider)
                    result = subprocess.run([shell, '-f', '-c', '. "$1"; ' + code,
                                             'reconnect-test', str(SCRIPT)], env=env,
                                            text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('[Wait]', result.stdout)
                    self.assertEqual(probes.read_text().splitlines(), ['probe', 'probe'])
                    self.assertEqual((slot / 'lock/owner').read_text(), owner)
                    self.assertTrue((slot / 'wake').exists())
