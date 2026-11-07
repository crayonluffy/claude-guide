"""Run real launchers with another account's listener hidden from process queries."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/claude-proxy.sh'


class SharedProxyChecks:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='shared-proxy-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.conf = self.root / 'proxy.conf'
        self.settings = self.root / 'settings.json'
        self.trace = self.root / 'app.trace'
        self.management = self.root / 'management.trace'
        self.conf.write_text('CLAUDE_PROXY_BANNER=0\nCLAUDE_PROXY_MODE=shared\n'
                             'CLAUDE_HTTP_PORT=18080\nCLAUDE_SOCKS_PORT=11080\n'
                             'CLAUDE_WATCHDOG_STARTUP_GRACE=0\nCLAUDE_SYNC_SETTINGS=1\n')
        binaries = self.root / 'bin'
        binaries.mkdir()
        for name in ('claude', 'codex'):
            binary = binaries / name
            binary.write_text('#!/bin/sh\n[ "${1:-}" != --help ] || exit 0\n'
                              'printf "%s\\n" "$HTTPS_PROXY" "$HTTP_PROXY" > "$APP_TRACE"\n')
            binary.chmod(0o700)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('CLAUDE_', '_CLAUDE_'))}
        self.env.update(HOME=str(self.root), PATH=str(binaries) + ':' + os.environ['PATH'],
                        APP_TRACE=str(self.trace), CLAUDE_PROXY_CONF=str(self.conf),
                        CLAUDE_SETTINGS=str(self.settings),
                        CLAUDE_TUNNEL_LOG=str(self.root / 'tunnel.log'),
                        CLAUDE_PROXY_NODES=str(self.root / 'nodes.json'),
                        XDG_STATE_HOME=str(self.root / 'state'))

    def run_shell(self, code):
        boundary = ('_listeners() { :; }; _port_bound() { return 0; }; '
                    '_conf_reload() { . "$CLAUDE_PROXY_CONF"; }; '
                    '_recovery_probe() { echo "healthy|0|200|404|healthy"; }; '
                    '_recovery_owner_start() { echo start >> ' + shlex.quote(str(self.management)) + '; return 88; }; '
                    '_recovery_owner_stop() { echo stop >> ' + shlex.quote(str(self.management)) + '; return 88; }; '
                    'sleep() { :; }; ')
        return subprocess.run([self.shell, '-f', '-c', '. "$1"; ' + boundary + code,
                               'shared-test', str(SCRIPT)], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def test_both_apps_use_shared_ports_without_creating_an_owner(self):
        for launcher in ('cc', 'cx'):
            with self.subTest(launcher=launcher):
                result = self.run_shell(launcher + ' --safe --no-verify --version')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.trace.read_text().splitlines(),
                                 ['http://127.0.0.1:18080'] * 2)
                self.assertFalse(self.management.exists(), 'Shared client managed the owner')
                self.assertFalse((self.root / 'state/claude-proxy/recovery').exists())
                settings = json.loads(self.settings.read_text())
                self.assertEqual(settings['env']['HTTPS_PROXY'], 'http://127.0.0.1:18080')

    def test_shared_client_refuses_failed_transport_and_direct_bypass(self):
        for code in ('_recovery_probe() { echo "tunnel|7|000|000|tunnel"; }; ',
                     'CLAUDE_NO_PROXY=api.openai.com; '):
            with self.subTest(code=code):
                result = self.run_shell(code + 'cx --safe --no-verify --version')
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.trace.exists(), 'Unsafe shared launch started the app')
                self.assertFalse(self.management.exists())

    def test_shared_controls_cannot_stop_restart_or_switch_the_owner(self):
        for command in ('tunnel-stop', 'proxy-restart', 'proxy-node jp'):
            with self.subTest(command=command):
                result = self.run_shell(command)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('shared', (result.stdout + result.stderr).lower())
                self.assertFalse(self.management.exists())
        result = self.run_shell('cc-stop --force')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.management.exists())


@unittest.skipUnless(shutil.which('bash'), 'bash unavailable')
class BashSharedProxyTests(SharedProxyChecks, unittest.TestCase):
    shell = 'bash'


@unittest.skipUnless(shutil.which('zsh'), 'zsh unavailable')
class ZshSharedProxyTests(SharedProxyChecks, unittest.TestCase):
    shell = 'zsh'
