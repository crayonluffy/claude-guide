#!/usr/bin/env python3
"""Run portable shell regressions without inheriting personal proxy settings."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("CLAUDE_", "_CLAUDE_"))}
    commands = [[sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py", "-v"],
                [sys.executable, "scripts/build-profiles.py", "--check"]]
    commands += [["bash", str(test.relative_to(ROOT))]
                 for test in sorted((ROOT / "tests").glob("*.sh"))]
    if shutil.which("zsh"):
        commands.append(["zsh", "tests/zsh-smoke.zsh"])
    else:
        print("SKIP: zsh smoke test (zsh unavailable)", flush=True)
    powershell = os.environ.get("PROXY_TEST_PWSH") or shutil.which("pwsh")
    if powershell:
        commands += [[powershell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(test.relative_to(ROOT))]
                     for test in sorted((ROOT / "tests").glob("*.ps1"))]
    else:
        print("SKIP: PowerShell tests (set PROXY_TEST_PWSH or install pwsh)", flush=True)
    for profile in sorted((ROOT / "scripts").glob("*.sh")):
        commands.append(["bash", "-n", str(profile.relative_to(ROOT))])
        if shutil.which("zsh"):
            commands.append(["zsh", "-n", str(profile.relative_to(ROOT))])
    failed = []
    for command in commands:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=120)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
            output += "\nTimed out after 120 seconds.\n"
        name = " ".join(command)
        passed = process.returncode == 0
        print(("PASS: " if passed else "FAIL: ") + name, flush=True)
        if not passed:
            failed.append(name)
            print(output[-5000:], flush=True)
    print(f"\n{len(commands) - len(failed)}/{len(commands)} checks passed.", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
