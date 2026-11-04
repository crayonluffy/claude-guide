"""Run real shell startup against isolated settings and tunnel records."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/claude-proxy.sh"
SHELLS = [shell for shell in ("zsh", "bash") if shutil.which(shell)]


class ShellStartupTests(unittest.TestCase):
    def check_startup(self, shell, owner):
        with tempfile.TemporaryDirectory(prefix="claude-proxy-startup-") as tmp:
            root = Path(tmp)
            settings = root / "settings.json"
            settings.write_text(json.dumps({"unrelated": {"keep": True}}))
            conf = root / "proxy.conf"
            conf.write_text("\n".join([
                "CLAUDE_PROXY_BANNER=0",
                "CLAUDE_KILLSWITCH=on",
                "CLAUDE_SYNC_SETTINGS=1",
                "CLAUDE_HTTP_PORT=8080",
                "CLAUDE_SETTINGS=" + shlex.quote(str(settings)),
            ]))
            if owner != "missing":
                slot = root / "state/claude-proxy/recovery/main"
                (slot / "lock").mkdir(parents=True)
                pid = os.getpid()
                if Path(f"/proc/{pid}/stat").exists():
                    stamp = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
                else:
                    stamp = subprocess.check_output(
                        ["ps", "-p", str(pid), "-o", "lstart="],
                        env={**os.environ, "LC_ALL": "C"}, text=True,
                    ).strip()
                if owner == "stale":
                    stamp = "old process identity"
                (slot / "lock/owner").write_text(f"{pid}\n{stamp}\n")
                (slot / "tunnel.rec").write_text(
                    "host=test-node\nuser=\nport=22\nkey=\n"
                    "http=8081\nsocks=1080\nremote=8888\n"
                )

            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("CLAUDE_", "_CLAUDE_"))}
            env.update(CLAUDE_PROXY_CONF=str(conf),
                       CLAUDE_PROXY_NODES=str(root / "nodes.json"),
                       XDG_STATE_HOME=str(root / "state"))
            expected = "8081" if owner == "live" else "8080"
            for window in (1, 2):
                result = subprocess.run(
                    [shell, "-f", "-c", '. "$1"; printf "%s\\n" "$CLAUDE_HTTP_PORT"',
                     "startup-test", str(SCRIPT)],
                    env=env, text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected,
                                 f"{shell} window {window}: wrong startup port")
                data = json.loads(settings.read_text())
                self.assertEqual(data["env"]["HTTPS_PROXY"],
                                 "http://127.0.0.1:" + expected)
                self.assertEqual(data["env"]["HTTP_PROXY"],
                                 "http://127.0.0.1:" + expected)
                self.assertEqual(data["unrelated"], {"keep": True})
                if window == 1:
                    first_write = settings.stat().st_mtime_ns
                else:
                    self.assertEqual(settings.stat().st_mtime_ns, first_write,
                                     "opening another window rewrote shared settings")

    def test_new_window_keeps_live_tunnel_port(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.check_startup(shell, "live")

    def test_without_owner_uses_configured_port(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.check_startup(shell, "missing")

    def test_stale_owner_does_not_override_configured_port(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                self.check_startup(shell, "stale")


if __name__ == "__main__":
    unittest.main()
