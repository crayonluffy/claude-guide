# 💡 Claude Code & Codex Tips

> This page agrees with Claude Code **v2.1.150** (May 2026). To see your version, type `claude --version`. To update, type `claude update`.

## Command-line flags

| Flag | What it does |
|------|-------------|
| `claude` | Starts an interactive session. |
| `claude "query"` | Starts a session with a first prompt. |
| `claude -c` | Continues the most recent conversation. |
| `claude -r` | Shows a list of old sessions. You select one to continue. |
| `claude -p "query"` | Print mode: runs one prompt without interaction, then stops. |
| `claude --model sonnet` | Selects a model: `sonnet`, `opus`, `haiku`, or a full ID (`claude-opus-4-7`, `claude-sonnet-4-6`). |
| `claude --effort high` | Sets the effort level: `low`, `medium`, `high`, `xhigh`, `max`, `auto`. |
| `claude --permission-mode plan` | Starts in a mode: `default`, `acceptEdits`, `plan`, `bypassPermissions`. |
| `claude --dangerously-skip-permissions` | Does not ask for permission. |
| `claude -w` / `--worktree` | Runs in a separate git worktree. |
| `claude --agent <name>` | Uses a specific subagent for the main thread. |
| `claude --max-turns 5` | Sets the maximum number of agent turns (print mode). |
| `claude --verbose` | Writes more data to the log. |
| `claude update` | Updates to the latest version. |
| `claude --version` | Shows the version number. |

## Slash commands (in an interactive session)

| Command | What it does |
|---------|---------|
| `/help` | Shows help and the available commands. |
| `/clear` | Clears the conversation history. |
| `/compact` | Makes the conversation shorter to free context. |
| `/context` | Shows how much of the context window is in use. |
| `/cost` | Shows the token use and cost (alias `/usage`). |
| `/model` | Changes the model. |
| `/effort` | Sets the effort level. |
| `/fast` | Sets fast mode on or off (faster Opus output). |
| `/config` | Opens the settings (alias `/settings`). |
| `/status` | Shows the version, the model and the account. |
| `/doctor` | Finds installation problems. |
| `/memory` | Edits the CLAUDE.md of the project. |
| `/init` | Makes a CLAUDE.md for the project. |
| `/diff` | Shows the changes that are not committed. |
| `/rewind` | Removes edits or goes back to a checkpoint (also `Esc Esc`). |
| `/plan` | Starts plan mode: Claude analyzes but does not make changes. |
| `/resume` | Continues an old session. (From the shell: `cc -c` continues the last session; `cc -r` shows a list.) |
| `/fork` | Makes a branch of the current conversation. |
| `/agents` | Manages subagents and background sessions. |
| `/code-review` | Examines the current diff for bugs (`--comment` writes comments on a PR). |
| `/ultrareview` | Runs a multi-agent review of the branch in the cloud (or `/ultrareview <PR#>`). |
| `/run` · `/verify` | Starts and uses the real application to make sure that a change works. |
| `/export` | Exports the conversation as text. |
| `/copy` | Copies the last answer to the clipboard. |
| `/bug` | Sends feedback (alias `/feedback`). |

> **Note:** The `/vim` command does not exist any more. To use Vim keys, open `/config` and set the editor mode (or set `"editorMode": "vim"` in settings.json).

**Automation and advanced commands.** Some of these are skills that come with Claude Code. To see the commands of your version, type `/help`.

| Command | What it does |
|---------|---------|
| `/goal [condition]` | Sets a condition. Claude continues to work until the condition is true. |
| `/batch <instruction>` | Divides a large change into parallel units. Each unit has its own worktree and PR. |
| `/loop [interval] [cmd]` | Runs a prompt or command again and again, at an interval (or at its own speed). |
| `/schedule` | Makes and manages scheduled agents (cron). |
| `/tasks` | Shows and manages background tasks. |
| `/background` · `/bg` | Moves the current session to the background. |
| `/autofix-pr [prompt]` | Monitors a PR and corrects CI failures and review comments. |
| `/teleport` | Moves a session from claude.ai into your terminal. |
| `/remote-control` · `/rc` | Lets you control this terminal session from claude.ai. |
| `/ultraplan` | Writes a plan in a cloud session. You examine it in the browser. |
| `/security-review` | Examines the changes for security problems. |
| `/tui [fullscreen]` | Changes the screen mode (for example, full screen without flicker). |
| `/voice [hold\|tap\|off]` | Sets voice input on or off. |
| `/team-onboarding` | Makes a team onboarding guide from your use. |

## Keyboard shortcuts

| Shortcut | What it does |
|----------|-------------|
| `Ctrl+C` | Cancels the current answer. |
| `Esc` | Stops Claude during an answer. |
| `Ctrl+D` | Closes Claude Code. |
| `Ctrl+L` | Clears the terminal screen. |
| `Ctrl+O` | Shows or hides the full transcript (all tool output). |
| `Shift+Tab` | Changes the permission mode (default → acceptEdits → plan → …). |
| `Esc Esc` | Opens the rewind and checkpoint menu. |
| `\ + Enter` | Starts a new line (also `Shift+Enter`). |
| `Ctrl+G` | Opens the prompt in your `$EDITOR`. |
| `Alt+P` | Changes the model (Option+P on macOS). |
| `Alt+T` | Sets extended thinking on or off (Option+T on macOS). |
| `!` | Shell mode: runs a command directly. |
| `@` | Completes a file path. |
| `/` | Opens the slash-command and skills menu. |

## Configuration

**Locations of the settings files:**

- **User:** `~/.claude/settings.json`. It applies to all projects.
- **Project:** `.claude/settings.json`. Your team uses it too.
- **Local:** `.claude/settings.local.json`. It is personal, and git ignores it.

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

> **Note:** With the kill switch on, the proxy profile also keeps `env.HTTPS_PROXY`, `env.HTTP_PROXY` and `env.NO_PROXY` in your user `settings.json`. Do not remove them by hand. To change this, use `proxy-killswitch`.

Current model IDs: `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`. Or use the aliases `opus`, `sonnet` and `haiku`. The aliases always use the latest version.

**CLAUDE.md**: make this file in the root folder of your project. It gives Claude permanent data about your project: coding standards, architecture, and common commands. Claude reads it automatically when it starts.

## Claude Code tips

- When the context is full, type `/compact` to free space (or let auto-compact do it).
- To send a file to Claude: `cat logs.txt | claude -p "summarize the errors"`.
- To send the output of Claude to a different tool: `claude -p "query" | command`.
- To remove changes and go back to a checkpoint, push `Esc Esc` or type `/rewind`.
- Before you commit, type `/diff` to examine all changes.
- To work in a separate git worktree, type `claude -w`. This is good for parallel work.
- For faster Opus output, type `/fast`. To set more or less reasoning, type `/effort`.
- To analyze without changes, type `/plan`.
- If something does not work correctly, type `/doctor`.

## Codex CLI basics

| Command | What it does |
|---------|---------|
| `codex` | Starts an interactive session. By default, it asks for approval before edits and commands. |
| `codex "task"` | Starts a session with a first prompt. |
| `codex resume` | Continues an old session (through the proxy: `cx resume`). |
| `codex exec "task"` | Runs one task without interaction, then stops. |
| `codex --full-auto` | Edits and runs commands automatically, in a sandbox. |
| `codex --dangerously-bypass-approvals-and-sandbox` | Does not ask for approval. `cx` uses this flag. |
| `codex --version` | Shows the version number. |

In a session, `/model` changes the model, and `/approvals` changes the approval mode. **`AGENTS.md`** is the Codex equivalent of `CLAUDE.md`: Codex reads it automatically for data about the project. For the current reference, refer to the [Codex docs](https://developers.openai.com/codex/).
