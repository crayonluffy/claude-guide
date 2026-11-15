#!/usr/bin/env python3
"""Guide checks: links, sidebar, flag spelling and renamed commands.

These were one-off scripted checks in the 2026-11-07 audit; here they run with
every test run, so a page or an installer cannot drift again unnoticed.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOCS = ROOT / "docs"
SIDEBAR = DOCS / "_sidebar.md"
CHANGELOG = DOCS / "changelog.md"
# Pages of the published guide (docs/superpowers is working material, not the guide).
PAGES = [ROOT / "README.md"] + sorted(p for p in DOCS.glob("*.md") if p != SIDEBAR)
# For maintainers, read on GitHub: deliberately not in the site's sidebar.
MAINTAINER_PAGES = {"building-shell-profiles.md"}

# Old command names (see "Renamed commands" in docs/commands.md).
RENAMED = ("cc-safe", "cx-safe", "cx-stop", "proxy-doctor", "proxy-node",
           "chrome-profiles", "proxy-killswitch")
RENAMED_RE = re.compile(r"(?<![\w-])(%s)(?![\w-])" % "|".join(map(re.escape, RENAMED)))

# A PowerShell-style flag with a capital first letter: -Force, -NoVerify.
CAPITAL_FLAG_RE = re.compile(r"(?<![\w-])-[A-Z][A-Za-z]+\b")
# Built-in cmdlets (Verb-Noun) and the PowerShell program keep their own spelling.
BUILTIN_RE = re.compile(r"\b[A-Z][a-z]+-[A-Z][A-Za-z]+\b|\b(?:powershell|pwsh)(?:\.exe)?\b")

USER_COMMAND_RE = re.compile(
    r"^function\s+((?:proxy|tunnel|cc|cx|chrome)-[a-z-]+|cc|cx|claude|codex)(?![\w-])")


def rel(path):
    return str(path.relative_to(ROOT))


def slug(heading):
    """The anchor GitHub and docsify give a heading."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading.strip().replace("`", ""))
    return re.sub(r"[^\w\- ]", "", text.lower()).replace(" ", "-")


def prose_and_code(path):
    """Yield (line number, text, in_fence) for every line of a Markdown file."""
    fence = False
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        yield number, line, fence


def anchors(path):
    found = set()
    for _, line, fence in prose_and_code(path):
        match = None if fence else re.match(r"#{1,6}\s+(.*)", line)
        if match:
            found.add(slug(match.group(1)))
    return found


def code_fragments(path):
    """Yield (line number, fragment): each fenced line and each inline `span`."""
    for number, line, fence in prose_and_code(path):
        if fence:
            yield number, line
        else:
            for span in re.findall(r"`([^`]+)`", line):
                yield number, span


class GuideTests(unittest.TestCase):
    def test_relative_links_and_anchors_resolve(self):
        broken = []
        for page in PAGES + [SIDEBAR]:
            for number, line, fence in prose_and_code(page):
                if fence:
                    continue
                for target in re.findall(r"\[[^\]]*\]\(([^)\s]+)\)", line):
                    if re.match(r"[a-z][a-z0-9+.-]*:", target):
                        continue  # http:, https:, mailto:
                    path, _, fragment = target.partition("#")
                    if path == "/":
                        wanted = ROOT / "README.md"   # the site's home page
                    elif path.startswith("/"):
                        wanted = ROOT / path.lstrip("/")
                    elif path:
                        wanted = (page.parent / path).resolve()
                    else:
                        wanted = page
                    if not wanted.exists():
                        broken.append(f"{rel(page)}:{number}: {target} (no such file)")
                    elif fragment and wanted.suffix == ".md" and fragment not in anchors(wanted):
                        broken.append(f"{rel(page)}:{number}: {target} (no such heading)")
        self.assertEqual(broken, [], "Broken links:\n" + "\n".join(broken))

    def test_sidebar_lists_every_guide_page(self):
        listed = set(re.findall(r"\]\(/docs/([^)#]+)\)", SIDEBAR.read_text(encoding="utf-8")))
        pages = {p.name for p in DOCS.glob("*.md") if p != SIDEBAR}
        self.assertEqual(sorted(pages - listed - MAINTAINER_PAGES), [],
                         "Pages missing from docs/_sidebar.md (visitors cannot reach them)")
        self.assertEqual(sorted(listed - pages), [], "docs/_sidebar.md links to pages that do not exist")

    def test_command_flags_are_lowercase(self):
        # The guide shows every flag of our own commands in lowercase, also the
        # Windows ones (-fix, not -Fix). The changelog keeps what was true then.
        found = []
        for page in PAGES:
            if page == CHANGELOG:
                continue
            for number, fragment in code_fragments(page):
                if BUILTIN_RE.search(fragment):
                    continue
                for flag in CAPITAL_FLAG_RE.findall(fragment):
                    found.append(f"{rel(page)}:{number}: {flag}")
        self.assertEqual(found, [], "Capitalised command flags:\n" + "\n".join(found))

    def test_renamed_commands_are_not_recommended(self):
        # The old names still work but print "[Renamed]": the guide and the
        # installers must name the current command. The rename table itself and
        # the changelog are the two places that list the old names.
        found = []
        sources = [p for p in PAGES if p != CHANGELOG] + [ROOT / "scripts/setup.sh", ROOT / "scripts/setup.ps1"]
        for source in sources:
            in_table = False
            for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
                if line.startswith("#"):
                    in_table = source.suffix == ".md" and "renamed commands" in line.lower()
                if in_table:
                    continue
                for name in RENAMED_RE.findall(line):
                    found.append(f"{rel(source)}:{number}: {name}")
        self.assertEqual(found, [], "Renamed commands still recommended:\n" + "\n".join(found))

    def test_powershell_commands_declare_lowercase_parameters(self):
        # PowerShell ignores case when it reads a flag, but tab completion and
        # the built-in help show the declared spelling.
        lines = (ROOT / "scripts/claude-proxy.ps1").read_text(encoding="utf-8").splitlines()
        found, commands = [], 0
        for index, line in enumerate(lines):
            match = USER_COMMAND_RE.match(line)
            if not match:
                continue
            commands += 1
            for offset in range(0, 5):
                if index + offset >= len(lines):
                    break
                candidate = lines[index + offset]
                if offset and candidate.startswith("function "):
                    break
                if "param(" in candidate:
                    for name in re.findall(r"\]\s*\$([A-Za-z_][A-Za-z0-9_]*)", candidate):
                        if name[0].isupper():
                            found.append(f"{match.group(1)} (line {index + offset + 1}): -{name}")
                    break
        self.assertGreater(commands, 15, "user-facing PowerShell commands not found")
        self.assertEqual(found, [], "Capitalised parameters:\n" + "\n".join(found))


if __name__ == "__main__":
    unittest.main()
