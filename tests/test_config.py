"""Exercise real config commands with private files and live owner fixtures."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/claude-proxy.sh"


class ConfigChecks:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="proxy-config-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.conf = self.root / "proxy.conf"
        self.conf.write_text("# personal setting\nCLAUDE_SYNC_SETTINGS=0\nCLAUDE_PROXY_BANNER=0\nCLAUDE_SSH_HOST=personal-host\n")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CLAUDE_", "_CLAUDE_"))}
        self.env.update(CLAUDE_PROXY_CONF=str(self.conf),
                        CLAUDE_PROXY_NODES=str(self.root / "nodes.json"),
                        CLAUDE_SETTINGS=str(self.root / "settings.json"),
                        XDG_STATE_HOME=str(self.root / "state"))
        self.owner("main", 8081, 1080)
        self.owner("node-sg", 8181, 1181)

    def owner(self, slot, http, socks):
        path = self.root / "state/claude-proxy/recovery" / slot
        (path / "lock").mkdir(parents=True)
        pid = os.getpid()
        proc = Path(f"/proc/{pid}/stat")
        stamp = (proc.read_text().rsplit(") ", 1)[1].split()[19] if proc.exists()
                 else subprocess.check_output(["ps", "-p", str(pid), "-o", "lstart="],
                      env={**os.environ, "LC_ALL": "C"}, text=True).strip())
        (path / "lock/owner").write_text(f"{pid}\n{stamp}\n")
        (path / "tunnel.rec").write_text(
            f"host={slot}-host\nuser=\nport=22\nkey=\nhttp={http}\nsocks={socks}\nremote=8888\n")

    def run_shell(self, code):
        return subprocess.run([self.shell, "-f", "-c", '. "$1"; ' + code,
                               "config-test", str(SCRIPT)], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def editor(self, body):
        editor = self.root / "editor with spaces"
        editor.write_text("#!/bin/sh\n" + body + "\n")
        editor.chmod(0o700)
        self.env["EDITOR"] = str(editor)

    def test_show_separates_saved_and_active_ports_for_every_node(self):
        result = self.run_shell("proxy-config show")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Saved", result.stdout)
        self.assertIn("8080", result.stdout)
        self.assertIn("Active node ports", result.stdout)
        for value in ("main-host", "8081", "node-sg-host", "8181", "1181", "8888"):
            self.assertIn(value, result.stdout)
        self.assertIn("use-active", result.stdout)

    def test_edit_sparse_config_exposes_ports_and_all_active_nodes(self):
        capture = self.root / "seen.conf"
        self.editor('cp "$1" ' + shlex.quote(str(capture)))
        result = self.run_shell("proxy-config edit")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = capture.read_text()
        for key in ("HTTP_PORT", "SOCKS_PORT", "REMOTE_PROXY_PORT", "SSH_PORT",
                    "NODE_HTTP_BASE", "NODE_SOCKS_BASE"):
            self.assertRegex(seen, rf'(?m)^CLAUDE_{key}="[0-9]+"$')
        for value in ("main-host", "8081", "node-sg-host", "8181", "1181"):
            self.assertIn(value, seen)
        self.assertIn("CLAUDE_SSH_HOST=personal-host", self.conf.read_text())
        self.assertIn("proxy-restart", result.stdout)
        self.assertNotIn("applied in this shell", result.stdout)

    def test_cancelled_editor_does_not_save_or_claim_success(self):
        self.editor("exit 7")
        before = self.conf.read_bytes()
        result = self.run_shell("proxy-config edit")
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertNotIn("[OK]", result.stdout)
        self.assertEqual(self.conf.read_bytes(), before)

    def test_invalid_port_is_rejected_without_saving(self):
        before = self.conf.read_bytes()
        for value in ("0", "65536", "banana", "-1", "08080"):
            with self.subTest(value=value):
                result = self.run_shell("proxy-config set HTTP_PORT " + shlex.quote(value))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.conf.read_bytes(), before)

    def test_invalid_editor_changes_do_not_replace_config(self):
        self.editor('printf "\\nCLAUDE_HTTP_PORT=invalid\\n" >> "$1"')
        before = self.conf.read_bytes()
        result = self.run_shell("proxy-config edit")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.conf.read_bytes(), before)
        self.assertNotIn("[OK]", result.stdout)

    def test_use_active_saves_main_ports_without_changing_other_settings(self):
        result = self.run_shell("proxy-config use-active")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for key, value in (("HTTP_PORT", "8081"), ("SOCKS_PORT", "1080"), ("SSH_PORT", "22"),
                           ("REMOTE_PROXY_PORT", "8888")):
            self.assertIn(f'CLAUDE_{key}="{value}"', self.conf.read_text())
        self.assertIn("CLAUDE_SSH_HOST=personal-host", self.conf.read_text())

    def test_set_explains_saved_port_is_pending_and_keeps_live_port(self):
        result = self.run_shell('proxy-config set HTTP_PORT 8090; printf "LIVE=%s\\n" "$CLAUDE_HTTP_PORT"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CLAUDE_HTTP_PORT="8090"', self.conf.read_text())
        self.assertIn("LIVE=8081", result.stdout)
        self.assertIn("proxy-restart", result.stdout)
        self.assertNotIn("applied in this shell", result.stdout)

    def test_no_owner_cannot_save_active_ports(self):
        shutil.rmtree(self.root / "state")
        before = self.conf.read_bytes()
        result = self.run_shell("proxy-config use-active")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.conf.read_bytes(), before)

    def test_reopening_editor_refreshes_snapshot_without_duplicate_sections(self):
        self.node_catalogue()
        self.editor(":")
        self.assertEqual(self.run_shell("proxy-config edit").returncode, 0)
        record = self.root / "state/claude-proxy/recovery/node-sg/tunnel.rec"
        record.write_text(record.read_text().replace("http=8181", "http=8191"))
        self.assertEqual(self.run_shell("proxy-config edit").returncode, 0)
        content = self.conf.read_text()
        self.assertEqual(content.count("# BEGIN CLAUDE PROXY PORT STATUS"), 1)
        self.assertEqual(content.count("# BEGIN CLAUDE NODE PORTS"), 1)
        # The running snapshot is refreshed; sg's saved assignment (8181) stays.
        self.assertRegex(content, r"(?m)^#\s+sg\s+node-sg-host\s+8191\s")
        self.assertNotRegex(content, r"(?m)^#\s+sg\s+node-sg-host\s+8181\s")
        self.assertRegex(content, r"(?m)^#\s+sg\s+8181\s+1181\s+8191/1181\s")
        self.assertRegex(content, r"(?m)^sg 8181 1181'?$")

    def test_status_moves_raw_recovery_fields_to_debug(self):
        code = ('_tunnel_health() { echo down; }; '
                '_node_status_lines() { :; }; '
                'proxy-notify() { :; }; ')
        normal = self.run_shell(code + "proxy-status")
        debug = self.run_shell(code + "proxy-status --debug")
        self.assertEqual(normal.returncode, 0, normal.stderr)
        self.assertIn("Active node ports", normal.stdout)
        self.assertNotIn("phase | outage start", normal.stdout)
        self.assertIn("phase | outage start", debug.stdout)

    def test_restart_reads_saved_ports_after_stopping_old_tunnel(self):
        with self.conf.open("a") as config:
            config.write("CLAUDE_HTTP_PORT=8090\n")
        trace = self.root / "restart.trace"
        # Only transport boundaries are replaced; the actual restart function
        # must reload configuration after stopping the old tunnel.
        code = ('_recovery_adopt() { CLAUDE_HTTP_PORT=8081; }; '
                'tunnel-stop() { echo stop >> ' + shlex.quote(str(trace)) + '; }; '
                '_conf_reload() { . "$CLAUDE_PROXY_CONF"; }; '
                'tunnel-start() { echo "start:$CLAUDE_HTTP_PORT" >> ' + shlex.quote(str(trace)) + '; }; '
                'proxy-on() { :; }; _proxy_probe() { echo "ok 0 200 404"; }; '
                'proxy-restart')
        result = self.run_shell(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["stop", "start:8090"])
        self.assertIn("relaunch", result.stdout.lower())
        self.assertNotIn("other windows recover on their next request", result.stdout)

    def node_catalogue(self):
        (self.root / "nodes.json").write_text(json.dumps({"nodes": [
            {"name": "jp", "alias": "main-host", "host": "192.0.2.1", "slot": 0},
            {"name": "sg", "alias": "node-sg-host", "host": "192.0.2.2", "slot": 1},
        ]}))

    def test_pending_node_base_changes_keep_existing_owner_ports(self):
        self.node_catalogue()
        result = self.run_shell(
            'proxy-config set NODE_HTTP_BASE 9000 >/dev/null; '
            'proxy-config set NODE_SOCKS_BASE 1900 >/dev/null; '
            '(_node_ctx sg && printf "PORTS=%s:%s\\n" "$CLAUDE_HTTP_PORT" "$CLAUDE_SOCKS_PORT")')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PORTS=8181:1181", result.stdout)

    def test_node_restart_probes_new_port_after_reload(self):
        self.node_catalogue()
        trace = self.root / "node-restart.trace"
        # The edit happens after shell startup, just like an external editor.
        code = ('printf "\\nCLAUDE_NODE_HTTP_BASE=9000\\nCLAUDE_SSH_HOST=node-sg-host\\n" >> "$CLAUDE_PROXY_CONF"; '
                '_conf_reload() { . "$CLAUDE_PROXY_CONF"; _recovery_adopt; }; '
                'tunnel-stop() { rm -f "$XDG_STATE_HOME/claude-proxy/recovery/node-sg/lock/owner"; }; '
                'tunnel-start() { (_node_ctx "$1" && echo "start:$CLAUDE_HTTP_PORT") >> ' + shlex.quote(str(trace)) + '; }; '
                '_proxy_probe() { echo "probe:$1" >> ' + shlex.quote(str(trace)) + '; echo "ok 0 200 404"; }; '
                'proxy-restart sg')
        result = self.run_shell(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["start:9001", "probe:9001"])
        self.assertIn("relaunch", result.stdout.lower())

    def test_active_ssh_ports_resolve_alias_settings(self):
        ssh_config = self.root / "ssh_config"
        ssh_config.write_text("Host main-host\n    Port 2222\nHost node-sg-host\n    Port 2200\n")
        self.env["TEST_SSH_CONFIG"] = str(ssh_config)
        result = self.run_shell('ssh() { command ssh -F "$TEST_SSH_CONFIG" "$@"; }; proxy-config show')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2222", result.stdout)
        self.assertIn("2200", result.stdout)

    def test_restart_rejects_other_nodes_port_before_stopping_anything(self):
        trace = self.root / "stop.trace"
        code = ('printf "\\nCLAUDE_HTTP_PORT=8181\\n" >> "$CLAUDE_PROXY_CONF"; '
                'tunnel-stop() { echo stopped >> ' + shlex.quote(str(trace)) + '; }; '
                '_conf_reload() { . "$CLAUDE_PROXY_CONF"; }; '
                'tunnel-start() { :; }; proxy-on() { :; }; '
                '_proxy_probe() { echo "ok 0 200 404"; }; proxy-restart')
        result = self.run_shell(code)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(trace.exists(), "A conflicting port change stopped a running tunnel")
        self.assertIn("8181", result.stdout + result.stderr)

    def named_restart_code(self, trace, prefix=""):
        # Real proxy-restart, slot selection and preflight; only the transport
        # boundaries are replaced. Stopping sg ends its owner so the new start
        # resolves saved ports instead of adopting the old record.
        sg_owner = self.root / "state/claude-proxy/recovery/node-sg/lock/owner"
        return (prefix +
                'tunnel-stop() { echo "stop:${1:-main}" >> ' + shlex.quote(str(trace)) + '; '
                '  [ "${1:-}" != sg ] || rm -f ' + shlex.quote(str(sg_owner)) + '; }; '
                'tunnel-start() { (_node_ctx "${1:-main}" && echo "start:${1:-main}:$CLAUDE_HTTP_PORT") >> '
                + shlex.quote(str(trace)) + '; }; '
                'proxy-on() { echo proxy-on >> ' + shlex.quote(str(trace)) + '; }; '
                '_proxy_probe() { echo "ok 0 200 404"; }; '
                'proxy-restart sg')

    def assert_only_named_slot_restarted(self, trace, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # Explicit node routes keep their node-<name> slot even when saved
        # settings make that node the default; main is never touched.
        self.assertEqual(trace.read_text().splitlines(), ["stop:sg", "start:sg:9001"])
        main = self.root / "state/claude-proxy/recovery/main"
        self.assertTrue((main / "lock/owner").exists(), "main owner was disturbed")
        self.assertIn("http=8081\n", (main / "tunnel.rec").read_text())

    def test_node_restart_keeps_named_slot_when_pending_default_is_that_node(self):
        self.node_catalogue()
        trace = self.root / "restart.trace"
        code = self.named_restart_code(trace, (
            'CLAUDE_SSH_HOST=main-host; '
            'printf "\\nCLAUDE_SSH_HOST=node-sg-host\\nCLAUDE_NODE_HTTP_BASE=9000\\n" >> "$CLAUDE_PROXY_CONF"; '
            '_conf_reload() { . "$CLAUDE_PROXY_CONF"; }; '))
        self.assert_only_named_slot_restarted(trace, self.run_shell(code))

    def test_restart_rejects_identical_http_and_socks_before_stopping(self):
        trace = self.root / "stop.trace"
        code = ('printf "\\nCLAUDE_HTTP_PORT=8090\\nCLAUDE_SOCKS_PORT=8090\\n" >> "$CLAUDE_PROXY_CONF"; '
                'tunnel-stop() { echo stopped >> ' + shlex.quote(str(trace)) + '; }; '
                '_conf_reload() { . "$CLAUDE_PROXY_CONF"; }; '
                'tunnel-start() { :; }; proxy-on() { :; }; '
                '_proxy_probe() { echo "ok 0 200 404"; }; proxy-restart')
        result = self.run_shell(code)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(trace.exists())

    def test_node_restart_keeps_named_slot_when_builtin_default_is_that_node(self):
        self.node_catalogue()
        catalogue = self.root / "nodes.json"
        data = json.loads(catalogue.read_text())
        data["nodes"][1]["alias"] = "jpvpn"
        catalogue.write_text(json.dumps(data))
        self.conf.write_text("CLAUDE_SYNC_SETTINGS=0\nCLAUDE_PROXY_BANNER=0\nCLAUDE_NODE_HTTP_BASE=9000\n")
        trace = self.root / "restart.trace"
        code = self.named_restart_code(trace, (
            'CLAUDE_SSH_HOST=main-host; '
            '_conf_reload() { CLAUDE_SSH_HOST=jpvpn; . "$CLAUDE_PROXY_CONF"; }; '))
        self.assert_only_named_slot_restarted(trace, self.run_shell(code))

    def test_node_restart_rejects_conflict_with_other_live_node_before_stopping(self):
        self.node_catalogue()
        self.owner("node-jp", 9001, 1190)
        trace = self.root / "restart.trace"
        code = self.named_restart_code(trace, (
            'printf "\\nCLAUDE_NODE_HTTP_BASE=9000\\n" >> "$CLAUDE_PROXY_CONF"; '
            '_conf_reload() { . "$CLAUDE_PROXY_CONF"; }; '))
        result = self.run_shell(code)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(trace.exists(), "A conflicting node port change stopped a tunnel")
        self.assertIn("node-jp", result.stdout + result.stderr)


@unittest.skipUnless(shutil.which("bash"), "bash not available")
class BashConfigTests(ConfigChecks, unittest.TestCase):
    shell = "bash"


@unittest.skipUnless(shutil.which("zsh"), "zsh not available")
class ZshConfigTests(ConfigChecks, unittest.TestCase):
    shell = "zsh"
