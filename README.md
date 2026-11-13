<p align="center"><img src="docs/assets/icon.png" width="128" alt="ClaudeTerm icon"></p>

<h1 align="center">ClaudeTerm</h1>

<p align="center">A native macOS terminal for running many Claude Code sessions at once.<br>
Ships with <code>ccgovd</code>, a daemon that puts idle sessions to sleep so they stop using memory.</p>

![ClaudeTerm](docs/screens/demo.png)

## Why

- **One window.** Every Claude Code session on the Mac, grouped by status, with live memory.
- **Nothing lost.** Quit or reboot, and each pane comes back with `claude --resume`.
- **Less memory.** 8 idle sessions went from 1.5 GB to 0 after one daemon cycle.
- **Real terminal.** Panes run on libghostty.

## Features

### Sessions

- Sidebar sections: *Needs you*, *Open here*, *Elsewhere*, *Asleep*, with a memory bar per session.
- Take over a session running in another terminal; several sessions per project.
- Right-click: pin, hibernate, reveal in Finder, copy the resume command.

### Toolbar

- Memory used by live sessions and the number asleep.
- Git branch of the selected session, with staged, modified, untracked and conflicted counts and commits ahead or behind.
- Weekly plan quota from Claude Code, with an even-pace marker and where you will be at reset at the current rate. The 5-hour window shows only when your plan has one.
- Today's API-equivalent cost; hover for the month total and month-end pace.

### Formatted Output

Turn it on and the pane shows the conversation with Claude's replies rendered as markdown: headings, lists, code blocks, tables, quotes. The live terminal stays below it for typing, permission prompts and menus. Turned off, nothing is read.

### Clipboard history

The last 50 texts copied in any app, searchable from the keyboard. Kept in memory only, and copies that password managers mark as private are skipped.

### Usage tab

Daily cost for the last 30 days (via [ccusage](https://github.com/ryoppippi/ccusage)); hover a day for tokens and models.

### Config tab

MCP servers, skills, agents and hooks for the selected session's project, each with its scope. Click a skill, agent or hook to reveal its file. MCP health is checked only when you click Check or Refresh, because `claude mcp list` starts every server. Read-only; `.env` files and settings `env` values are never read.

### Daemon (`ccgovd`)

- Indexes sessions with memory and CPU per process tree.
- Moves unfocused idle sessions to background priority, and hibernates sessions idle for 30 minutes; a click resumes them.
- Read-only unless started with `--govern`. Checks a process's identity before signalling it.

## Shortcuts

| Keys | Action |
|---|---|
| Cmd-1 ... Cmd-8, Cmd-9 | Pane 1 to 8, last pane |
| Ctrl-Tab, Cmd-Shift-] / [ | Next / previous pane |
| Cmd-Option-Down / Up | Next / previous session in the sidebar |
| Cmd-Ctrl-1 / 2 / 3, Cmd-Shift-U | Sessions / Usage / Config tab; toggle Sessions / Usage |
| Cmd-N, Cmd-Shift-N | New session, new session in this project |
| Cmd-Shift-W, Cmd-Ctrl-S | Close pane, toggle sidebar |
| Cmd-Shift-M | Formatted Output on / off |
| Cmd-Shift-V | Clipboard history: type to filter, Up / Down, Return to copy, Cmd-1 ... Cmd-9 to copy a row |

## Performance

Idle sessions, measured on 2026-11-07.

| | App | 8 idle sessions |
|---|---|---|
| Terminal.app | 56 MB | ~4.9 GB |
| Claude desktop app | 1.7 GB | not measured |
| ClaudeTerm | 81 MB | ~4.9 GB |
| ClaudeTerm + `ccgovd --govern` | 81 MB | **0** |

## Install

Needs macOS 14+, Xcode, Claude Code 2.1.319+, and a GitHub SSH key (the formula clones over SSH).

```sh
brew install 0xnicholasy/tap/claudeterm
ln -sf "$(brew --prefix claudeterm)/ClaudeTerm.app" /Applications/ClaudeTerm.app
brew services start claudeterm   # optional: ccgovd daemon, read-only
```

For the daemon to demote and hibernate idle sessions, run `ccgovd run --govern`.

## Updates

ClaudeTerm checks for a new release at launch and once a day (turn it off in **ClaudeTerm > About ClaudeTerm**). When one is out, the About window installs it with Homebrew and relaunches; panes come back with `claude --resume`. By hand:

```sh
brew upgrade 0xnicholasy/tap/claudeterm
```

Homebrew builds are signed ad hoc, because its build sandbox cannot reach your keychain, and macOS then asks for Desktop and Documents access again after each update. Updates installed from the About window re-sign the app with your Apple Development certificate, when the keychain has one, so permissions stay. After a manual `brew upgrade`, do the same with:

```sh
codesign --force --deep --sign "Apple Development" "$(cd "$(brew --prefix claudeterm)/ClaudeTerm.app" && pwd -P)"
```

## Build from source

```sh
scripts/build-app.sh           # builds and signs build/ClaudeTerm.app
cd ccgovd && make install-daemon
```

Set `CLAUDETERM_SIGN_IDENTITY` to choose a signing certificate. Hook setup: [`ccgovd/hooks/README.md`](ccgovd/hooks/README.md). Design notes: [`docs/design.md`](docs/design.md).

## Author

[0xnicholasy](https://github.com/0xnicholasy)
