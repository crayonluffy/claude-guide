import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlatformTests(unittest.TestCase):
    def test_generated_profiles_are_current(self):
        result = subprocess.run(["python3", "scripts/build-profiles.py", "--check"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_standalone_profiles_load_only_on_their_platform(self):
        native = "macos" if platform.system() == "Darwin" else "linux"
        for target in ("macos", "linux"):
            for shell in ("bash", "zsh"):
                if not shutil.which(shell):
                    continue
                with self.subTest(target=target, shell=shell), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    source = ROOT / f"scripts/claude-proxy-{target}.sh"
                    self.assertTrue(source.is_file(), f"Missing standalone {target} profile")
                    standalone = root / "profile.sh"
                    shutil.copyfile(source, standalone)
                    conf = root / "proxy.conf"
                    conf.write_text("CLAUDE_SYNC_SETTINGS=0\nCLAUDE_PROXY_BANNER=0\n")
                    env = {k: v for k, v in os.environ.items()
                           if not k.startswith(("CLAUDE_", "_CLAUDE_"))}
                    env.update(CLAUDE_PROXY_CONF=str(conf),
                               CLAUDE_PROXY_NODES=str(root / "nodes.json"),
                               XDG_STATE_HOME=str(root / "state"))
                    result = subprocess.run(
                        [shell, "-f", "-c", '. "$1" || exit $?; '
                         'printf "PLATFORM=%s\\n" "$_CLAUDE_PROXY_PLATFORM"; '
                         '_recovery_process_identity $$; _recovery_now',
                         "platform-test", str(standalone)], env=env,
                        capture_output=True, text=True, timeout=15,
                    )
                    if target == native:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertIn(f"PLATFORM={native}", result.stdout)
                        self.assertRegex(result.stdout.splitlines()[-1], r"^[0-9]+$")
                        self.assertGreater(len(result.stdout.splitlines()), 2)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertFalse((root / "state").exists(), "Wrong platform wrote state")

    def test_updater_chooses_native_download(self):
        native = "macos" if platform.system() == "Darwin" else "linux"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            conf = root / "conf"
            conf.write_text("CLAUDE_SYNC_SETTINGS=0\nCLAUDE_PROXY_BANNER=0\n")
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("CLAUDE_", "_CLAUDE_"))}
            env.update(CLAUDE_PROXY_CONF=str(conf), XDG_STATE_HOME=str(root / "state"))
            result = subprocess.run(
                ["bash", "-c", '. "$1"; curl() { printf "%s\\n" "$@" >&2; return 1; }; proxy-update --check',
                 "updater-test", str(ROOT / "scripts/claude-proxy.sh")],
                env=env, capture_output=True, text=True, timeout=10,
            )
            self.assertIn(f"/claude-proxy-{native}.sh", result.stderr)
