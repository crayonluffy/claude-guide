# 💡 Claude Code & Codex Tips

> Verified against Claude Code **v2.1.150** (May 2026). Check yours with `claude --version`, upgrade with `claude update`.

## CLI Flags

| Flag | Description |
|------|-------------|
| `claude` | Start an interactive session |
| `claude "query"` | Start with an initial prompt |
| `claude -c` | Continue the most recent conversation |
| `claude -r` | Resume a previous session (pick from a list) |
| `claude -p "query"` | Print mode — run non-interactively and exit |
| `claude --model sonnet` | Pick a model: `sonnet` / `opus` / `haiku`, or a full ID (`claude-opus-4-7`, `claude-sonnet-4-6`) |
| `claude --effort high` | Effort level: `low`, `medium`, `high`, `xhigh`, `max`, `auto` |
| `claude --permission-mode plan` | Start in a mode: `default`, `acceptEdits`, `plan`, `bypassPermissions` |
| `claude --dangerously-skip-permissions` | Skip all permission prompts |
| `claude -w` / `--worktree` | Run in an isolated git worktree |
| `claude --agent <name>` | Use a specific subagent for the main thread |
| `claude --max-turns 5` | Limit agentic turns (print mode) |
| `claude --verbose` | Enable verbose logging |
| `claude update` | Update to the latest version |
| `claude --version` | Show the version number |

## Slash Commands (Inside Interactive Mode)

| Command | Purpose |
|---------|---------|
| `/help` | Show help and available commands |
| `/clear` | Clear conversation history |
| `/compact` | Compact the conversation to free context |
| `/context` | Visualize context-window usage |
| `/cost` | Show token usage / cost (alias `/usage`) |
| `/model` | Change the model |
| `/effort` | Set the effort level |
| `/fast` | Toggle fast mode (faster Opus output) |
| `/config` | Open settings (alias `/settings`) |
| `/status` | Show version, model, account info |
| `/doctor` | Diagnose installation issues |
| `/memory` | Edit project CLAUDE.md |
| `/init` | Initialize the project with a CLAUDE.md |
| `/diff` | Review uncommitted changes |
| `/rewind` | Undo edits / restore a checkpoint (also `Esc Esc`) |
| `/plan` | Enter plan mode (analyze without executing) |
| `/resume` | Resume a previous session |
| `/fork` | Branch the current conversation |
| `/agents` | Manage subagents & background sessions |
| `/code-review` | Review the current diff for bugs (`--comment` posts to a PR) |
| `/ultrareview` | Multi-agent cloud review of the branch (or `/ultrareview <PR#>`) |
| `/run` · `/verify` | Launch & drive the real app to confirm a change works |
| `/export` | Export the conversation as text |
| `/copy` | Copy the last response to the clipboard |
| `/bug` | Submit feedback (alias `/feedback`) |

> Note: the standalone `/vim` command was removed — set Vim keys via `/config` → editor mode (or `"editorMode": "vim"` in settings.json).

**Automation & advanced** (newer; several are bundled skills — run `/help` to see what's installed on your version):

| Command | Purpose |
|---------|---------|
| `/goal [condition]` | Set a completion condition — Claude keeps working until it's met |
| `/batch <instruction>` | Split a large change into parallel units, each in its own worktree + PR |
| `/loop [interval] [cmd]` | Run a prompt/command repeatedly on an interval (or self-paced) |
| `/schedule` | Create / manage recurring scheduled agents (cron) |
| `/tasks` | List & manage background tasks |
| `/background` · `/bg` | Detach the current session as a background agent |
| `/autofix-pr [prompt]` | Watch a PR and auto-fix on CI failures / review comments |
| `/teleport` | Pull a claude.ai web session down into your terminal |
| `/remote-control` · `/rc` | Drive this terminal session from claude.ai |
| `/ultraplan` | Draft a plan in a cloud session, review it in the browser |
| `/security-review` | Security-focused review of the pending changes |
| `/tui [fullscreen]` | Switch the renderer (e.g. flicker-free fullscreen) |
| `/voice [hold\|tap\|off]` | Toggle voice dictation |
| `/team-onboarding` | Generate a team onboarding guide from your usage |

## Keyboard Shortcuts

| Shortcut | Description |
|----------|-------------|
| `Ctrl+C` | Cancel the current generation |
| `Esc` | Stop Claude mid-response |
| `Ctrl+D` | Exit Claude Code |
| `Ctrl+L` | Clear the terminal screen |
| `Ctrl+O` | Toggle the transcript view (full tool output) |
| `Shift+Tab` | Cycle permission modes (default → acceptEdits → plan → …) |
| `Esc Esc` | Open the rewind / checkpoint menu |
| `\ + Enter` | New line (also `Shift+Enter`) |
| `Ctrl+G` | Open the prompt in your `$EDITOR` |
| `Alt+P` | Switch model (Option+P on macOS) |
| `Alt+T` | Toggle extended thinking (Option+T on macOS) |
| `!` | Shell mode — run a command directly |
| `@` | File-path autocomplete |
| `/` | Slash-command / skills menu |

## Configuration

**Settings file locations:**
- **User:** `~/.claude/settings.json` (applies to all projects)
- **Project:** `.claude/settings.json` (shared with team)
- **Local:** `.claude/settings.local.json` (personal, gitignored)

**Example `settings.json`:**
```json
{
  "model": "claude-sonnet-4-6",
  "permissions": {
    "allow": ["Bash(npm run test *)", "Read"],
    "deny": ["Bash(curl *)"]
  },
  "attribution": {
    "commit": "",
    "pr": ""
  }
}
```

Current model IDs: `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5` — or use the aliases `opus` / `sonnet` / `haiku` to always track the latest.

**CLAUDE.md** — Create at project root to give Claude persistent context about your project (coding standards, architecture, common commands, etc.). It loads automatically when Claude starts.

## Claude Code Tips

- Use `/compact` when context fills up (or rely on auto-compact) to free space
- Pipe files into Claude: `cat logs.txt | claude -p "summarize the errors"`
- Use `claude -p "query" | command` to feed Claude's output into other tools
- `Esc Esc` or `/rewind` to undo changes and restore a checkpoint
- `/diff` to review everything before committing
- `claude -w` to work in an isolated git worktree — great for parallel features
- `/fast` for snappier Opus output; `/effort` to dial reasoning up or down
- `/plan` to analyze safely without making changes
- Run `/doctor` if something isn't working right

## Codex CLI Basics

| Command | Purpose |
|---------|---------|
| `codex` | Start an interactive session (asks approval before edits/commands by default) |
| `codex "task"` | Start with an initial prompt |
| `codex resume` | Resume a previous session |
| `codex exec "task"` | Non-interactive mode — run a task and exit |
| `codex --full-auto` | Auto-edit/run inside a sandbox (middle ground) |
| `codex --dangerously-bypass-approvals-and-sandbox` | Skip all approvals — what `cx` uses |
| `codex --version` | Show the version number |

Inside a session, `/model` switches models and `/approvals` changes the approval mode. The equivalent of `CLAUDE.md` is **`AGENTS.md`** — project context Codex loads automatically. See the [Codex docs](https://developers.openai.com/codex/) for the current reference.
