# Implementation plan: native Claude Code terminal

Research: `docs/research.md`. Status (2026-11-07): M1-M4 built and verified, integration done, M5 not needed (fleet RSS drop 100% after one governor cycle). See STATE.md.
Build order (decided 2026-11-07): **native app first**. Order: M0, M3, M4, M1, M2, M5. Until ccgovd exists (M1), the app sidebar reads `claude agents --json` directly.

## Finish line

- One window lists every Claude Code session on this Mac, across projects, grouped by project: running, idle, hibernated.
- Quitting the app or rebooting loses no session: each comes back as resumable via `claude --resume <id>`.
- With 8 sessions open, total Claude-related RSS is at least 40% below today's baseline (1.38 GB claude + ~300 MB children, measured 2026-11-07). Measured with the same `ps` script.

## Architecture

```
ClaudeTerm.app (Swift, AppKit + SwiftUI)
  sidebar: projects -> sessions (from ccgovd)
  panes:   libghostty-spm TerminalView, each runs `claude ...` in a PTY
        |
        | unix socket (JSON lines)
        v
ccgovd (launchd user agent, Swift CLI, no UI)
  index:     poll `claude agents --json` (5 s) + hook events (SessionStart/SessionEnd/Notification)
  store:     SQLite: sessionId, cwd, name, state, lastActivity, pinned, hibernated
  governor:  per-session RSS/CPU (proc_pidinfo over the process tree)
             unfocused        -> taskpolicy -b -p <pid tree>
             focused          -> taskpolicy -B -p <pid tree>
             idle > N min     -> SIGTERM tree, mark hibernated
             reopen           -> spawn `claude --resume <id>` in cwd
  mcp:       (later) shared HTTP daemons for stateless stdio MCPs
```

Ownership decisions:
- **The daemon owns the policy; the app is a UI.** The governor works with Ghostty today and keeps working if the app is closed.
- **PTYs live in the app.** Live sessions do not survive app quit. Restore is resume-from-transcript, the same as cmux. Live survival across app quit (a PTY-holder daemon) is out of scope until v2.
- **Session index = `claude agents --json` + hooks.** Never parse JSONL message bodies; the format is internal.

## Milestones

### M0. Quick wins, no new code in this repo (about 30 min)
- [x] Fix the statusline `ccusage` job (2026-11-07). Each refresh scans only files modified in the last day (symlink tree as `CLAUDE_CONFIG_DIR`); past days come from a ledger at `~/.cache/claude-statusline/ccusage-daily.json`, computed once per day. Refresh: 188 s / 2.1 GB down to 4.1 s / 395 MB. Backup: `~/.claude/statusline.sh.bak-20261107`
- [x] Close idle sessions: skipped. All 7 sessions had transcript writes within 28 min; the earlier "idle" figure was process uptime
- [x] Re-measured 2026-11-07 (after M0): 8 `claude` processes = 2.53 GB (up from 1.38 GB earlier the same day, same sessions growing), children 143 MB, no `ccusage` process resident. **Baseline for the 40% target: 2.53 GB + 0.14 GB = 2.67 GB at 8 sessions**

### M1. ccgovd: read-only index + metrics (about 1 day)
- [x] Swift package `ccgovd`, `swift build` green
- [x] Poll `claude agents --json`, store in SQLite
- [x] Per-session RSS/CPU across the process tree (claude + MCP children)
- [x] `ccgovd status` CLI prints the table. Pass: matches `ps` totals within 5%

### M2. Governor actions (about 1-2 days)
- [x] `ccgovd demote/restore <sessionId>` via `taskpolicy -b/-B -p` on the tree
- [x] Hibernate: SIGTERM tree after idle N min (default 30), skip pinned and `state != idle/blocked`
- [x] `ccgovd resume <sessionId>` prints the exact command for Ghostty use
- [x] Hook script: `SessionStart`/`SessionEnd`/`Notification` write to the socket
- [x] Pass: hibernate a real idle session, resume it, conversation history intact; RSS drop logged

### M3. App shell (about 2 days)
- [x] Xcode project, macOS 14+, Swift 6.2, libghostty-spm pinned to one release (ABI breaks expected before 1.0)
- [x] One pane running `claude` in a project dir, keyboard + paste + resize work
- [x] Sidebar from `claude agents --json` (poll 5 s; switch to `ccgovd` socket at M1): project groups, state, RSS via `ps`
- [x] Click hibernated session: new pane runs `claude --resume <id>` in its cwd
- [x] Pass: 8 panes open, app RSS under 150 MB (excluding claude processes)

### M4. Persistence (about 1 day)
- [x] Save layout (windows, panes -> sessionId, cwd) on change
- [x] On launch restore layout; resume lazily only when a pane is focused
- [x] Pass: quit app, reboot, relaunch: every pane reappears, focused one resumes

### M5. Shared MCP + browser (about 2-3 days, only if M0-M4 leave the target unmet)
- [ ] (skipped: target met without it) Run stateless stdio MCPs (discord, lcu) once behind an HTTP bridge; spawn sessions with `--mcp-config` pointing at it
- [ ] jev-browser stays per-session or moves to one CDP browser with per-session tabs
- [ ] Pass: 8 sessions, MCP child count drops from 24 to 3

## Open questions
- Hibernate default: 30 min idle. Change after a week of use.
- Repo is not a git repo yet; `git init` on first code milestone.

## Claude-native sidebar + usage stats (2026-11-08)

Finish line: tests pass, app builds, and live: sidebar groups by project, Cmd-numbers run top to bottom, a waiting session is highlighted and notifies, Usage tab shows daily/weekly/monthly/projects/blocks plus the weekly outlook line.

- [x] Project-first sidebar (decided 2026-11-08): open projects first in pane order, then other projects by name; nothing reorders on state change
- [x] Panes kept grouped by project, so Cmd-1..9 match sidebar order top to bottom
- [x] Waiting state: highlighted row, bell, status-strip label, macOS notification on transition, dock badge
- [x] Usage: week/month totals, weekly/monthly/projects (ccusage session)/blocks (ccusage blocks) lists
- [x] Weekly outlook: reserve, lasts-until-reset or run-out time, 5-hour windows left, est. 5-hour quotas left
- [ ] Live check in the app (screen capture was not permitted from the session, 2026-11-08)
