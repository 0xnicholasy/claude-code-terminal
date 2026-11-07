# SPEC: ClaudeTerm + ccgovd

Source plan: `tasks/todo.md`. Evidence: `docs/research.md`. This file fixes module layout, the socket protocol, and the done-contracts. It is high level; implementation details are the lane's call unless fixed here.

## 1. Module layout

```
Protocol/                      SwiftPM package "CCProtocol" (library CCProtocol), types only, no I/O
  Package.swift                swift-tools-version 6.2, macOS 14
  Sources/CCProtocol/*.swift   Codable request/response/event types, SessionInfo, SessionState, ResumeCommand, SocketPath
  Tests/CCProtocolTests/       JSON round-trip tests
ccgovd/                        SwiftPM package "ccgovd", depends on ../Protocol by path
  Package.swift
  Sources/CCGovCore/           library: index, store, metrics, governor, signal gate, socket server
  Sources/ccgovd/              executable: CLI (run, status, demote, restore, hibernate, pin, unpin, resume, hook)
  Tests/CCGovCoreTests/
  launchd/com.hotingyuen.ccgovd.plist
  hooks/                       ccgovd-hook settings snippet + README (opt-in, never auto-installed)
  Makefile                     build, test, install-daemon (copies binary + plist, does NOT run launchctl)
App/                           xcodegen project
  project.yml                  targets ClaudeTerm (macOS app, macOS 14+) and ClaudeTermTests; scheme ClaudeTerm
  Sources/ClaudeTerm/          AppKit + SwiftUI
  Tests/ClaudeTermTests/
```

Packages in `App/project.yml`:
- `libghostty-spm`: `https://github.com/Lakr233/libghostty-spm`, **exactVersion `2.2.2026103001`** (latest release, 2026-10-30). Product `GhosttyTerminal`. Its own transitive deps (DisplayLink) are accepted as part of it.
- `CCProtocol`: local path `../Protocol`.

No other dependencies. SQLite via the system `SQLite3` module (C API).

## 2. Session index facts (verified 2026-11-07, Claude Code 2.1.319)

`claude agents --json` returns an array. Two shapes:
- interactive: `{pid, cwd, kind:"interactive", startedAt(ms), sessionId, name, status:"idle"|"busy"}`
- background: `{id, cwd, kind:"background", startedAt, sessionId, name, state:"blocked"|...}` (no pid; owned by Claude's own supervisor; READ ONLY, never governed)

Decode both; unknown fields ignored; missing fields tolerated. Never read JSONL message bodies. Allowed: transcript file **mtime** and existence, found as `~/.claude/projects/*/<sessionId>.jsonl`.

The binary is `~/.local/bin/claude` (symlink into `~/.local/share/claude/versions/`). GUI apps and launchd do not get the login PATH: resolve `claude` once via `/bin/zsh -lc 'command -v claude'`, fall back to `~/.local/bin/claude`, overridable with `CCTERM_CLAUDE_PATH`.

## 3. Shared types (CCProtocol)

- `SessionState`: `running` (busy), `idle`, `blocked` (waiting on user/permission), `hibernated`, `unknown`.
- `SessionKind`: `interactive`, `background`, `hibernated`.
- `SessionInfo`: `sessionId`, `cwd`, `name?`, `kind`, `state`, `pid?`, `rssBytes` (claude + all descendants), `cpuPercent`, `childCount`, `pinned`, `demoted`, `focused`, `lastActivityMs?`, `hibernatedAtMs?`, `ownedByApp` (pane in ClaudeTerm).
- `ResumeCommand`: `cwd`, `argv` (e.g. `["claude","--resume","<id>"]`), `shellLine` (`cd '<cwd>' && claude --resume <id>`, single-quote escaped).
- `SocketPath.default`: `~/Library/Application Support/ccgovd/ccgovd.sock`; env override `CCGOVD_SOCKET`. Directory mode 0700, socket mode 0600, owner = current uid.
- `sessionId` must match the UUID regex before it is used in any argv or path. Reject otherwise.

## 4. Socket protocol (unix stream socket, newline-delimited JSON, UTF-8, max request line 64 KiB; daemon-to-client event lines may reach 1 MiB, the app's read cap, because a full sessions snapshot can exceed 64 KiB)

Request: `{"id":"<client id>","cmd":"<cmd>","sessionId":"<uuid>"?,"pids":[int]?,"hook":{...}?}`

| cmd | effect | response payload |
|---|---|---|
| `list` | current index | `sessions` |
| `status` | index + fresh metrics + totals | `sessions`, `totals {rssBytes, cpuPercent, count}` |
| `focus` | mark session focused (app pane gained focus); restores it if demoted | none |
| `unfocus` | clear focus | none |
| `demote` / `restore` | background / foreground the session tree | none |
| `hibernate` | SIGTERM the tree, record hibernated | none |
| `pin` / `unpin` | never hibernate when pinned | none |
| `resume` | look up cwd | `command: ResumeCommand` |
| `attach` | app declares it owns a pane for sessionId (sets `ownedByApp`) | none |
| `subscribe` | keep the connection open; daemon pushes events | stream of events |
| `hook` | hook event from `ccgovd hook` (`SessionStart`/`SessionEnd`/`Notification`, `session_id`, `cwd`, `transcript_path`) | none |

Response: `{"id":"<same id>","ok":true|false,"error":"..."?, "sessions":[...]?, "totals":{...}?, "command":{...}?}`
Event (subscribe only): `{"event":"sessions","sessions":[...]}` after every index cycle and every state change; `{"event":"hibernated"|"resumed"|"demoted"|"restored","sessionId":"..."}`.

Unknown `cmd`, malformed JSON, oversize line: `ok:false` with an error, connection stays usable for malformed lines, closes for oversize.

## 5. ccgovd behaviour

- **Index**: poll `claude agents --json` every 5 s (configurable). Merge into SQLite (`sessions` table: sessionId PK, cwd, name, kind, state, pid, pidStartTime, pinned, demoted, hibernated, hibernatedAt, lastActivity, updatedAt). Hibernated rows stay after the process is gone; they leave hibernated state when the session reappears in the index.
- **Metrics**: `proc_listallpids` + `proc_pidinfo` (`PROC_PIDTBSDINFO` for ppid/start time/comm, `PROC_PIDTASKINFO` for resident size and CPU time). Session RSS = claude pid + all descendants. CPU% = delta CPU time / delta wall time.
- **lastActivity** = max(transcript mtime, last hook event, last state change to busy).
- **Demote/restore**: `setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)` / `0` on every pid in the tree (the same API `taskpolicy -b/-B -p` uses). Verify with `getpriority(PRIO_DARWIN_PROCESS, pid)`. Policy when `--govern`: an interactive session that is not focused and is idle/blocked for >= 60 s is demoted; focus or `busy` restores it.
- **Hibernate** when `--govern`: interactive session, state idle or blocked, `now - lastActivity >= idleMinutes` (default 30, flag `--idle-minutes`, test flag `--idle-seconds`), not pinned, no active child command. Active child command = any descendant whose comm is a shell (`sh`, `bash`, `zsh`, `fish`, `dash`). Procedure: verify pid identity, SIGTERM every pid in the tree (children first, then claude), wait up to 5 s, SIGKILL survivors that still pass identity check, mark hibernated, log RSS freed.
- **Resume**: `ccgovd resume <id>` prints `ResumeCommand.shellLine`. The daemon itself never spawns `claude` for resume; the app (or the user in Ghostty) does.
- **SignalGate** (single choke point for every `kill` and `setpriority` call):
  1. pid > 1 and != own pid.
  2. Identity: the pid's current start time equals the start time recorded when it was first seen for that session; comm is `claude` for the root (descendants: start time recorded in the same metrics pass). Mismatch = pid reused, refuse.
  3. Scope: pid is the root of a known interactive session or one of its descendants in the current pass.
  4. **Test mode**: when an allowlist is configured (`--allow-pids` or `CCGOVD_ALLOW_PIDS`, roots; descendants of allowlisted roots are allowed), any pid outside it is refused and logged. `--scope-cwd-prefix <path>` additionally restricts governing to sessions whose cwd is under the prefix.
- **Safety default**: without `--govern`, the daemon only indexes and measures (read-only). `make install-daemon` installs a read-only plist; `make install-daemon GOVERN=1` adds `--govern` (changed after security review: governing every real session should be an explicit opt-in).
- **CLI**: `ccgovd run [--govern] [--interval s] [--idle-minutes n|--idle-seconds n] [--socket p] [--db p] [--allow-pids a,b] [--scope-cwd-prefix p] [--once]`; `ccgovd status [--json]` (socket if daemon is up, otherwise one-shot index+metrics in-process); `ccgovd demote|restore|hibernate|pin|unpin|resume <sessionId>`; `ccgovd hook` (reads hook JSON on stdin, forwards to socket, always exits 0 within 1 s).
- `status` table columns: SESSION (8 chars), PROJECT (cwd basename), STATE, PID, RSS MB, CPU%, CHILDREN, FLAGS (P=pinned, D=demoted, F=focused); last line TOTAL.

## 6. ClaudeTerm behaviour

- Window: `NavigationSplitView`-style. Sidebar = sessions grouped by project (cwd), each row: name, state badge (running / idle / blocked / hibernated), RSS MB. Detail = pane area (one or more terminal panes; a simple split or tab strip is enough).
- **Session source** protocol with two implementations: `AgentsPollingSource` (runs `claude agents --json` every 5 s plus a `ps -axo pid,ppid,rss` tree sum) and `DaemonSocketSource` (subscribe over the socket). Integration milestone picks the socket when it connects, falls back to polling when absent, re-checks every 10 s.
- **Panes**: libghostty `TerminalView`/`TerminalSurfaceView` with the package's exec backend running the resolved claude binary with an argv array and `cwd` set as the working directory (no shell string interpolation of cwd or ids). New session: app generates a UUID and runs `claude --session-id <uuid>` so the id is known up front. Resume: `claude --resume <uuid>`. Keyboard, paste (Cmd-V), and resize must work.
- **Hidden panes** set `isSurfaceVisible = false` to release GPU memory.
- **Layout persistence**: `~/Library/Application Support/ClaudeTerm/layout.json` (env override `CCTERM_LAYOUT_PATH`), written atomically on every change: windows -> panes `{sessionId, cwd, title}`, selected pane, window frame. On launch: restore all panes as placeholders (no process); spawn `claude --resume <id>` in its cwd only when a pane is focused/selected (lazy). Corrupt file: back it up as `layout.json.bad`, start empty.
- Clicking a hibernated (or any not-in-app) session in the sidebar opens a new pane running `claude --resume <id>` in its cwd; for live sessions owned by another terminal, show a non-destructive notice instead of starting a second process on the same session.
- When the socket is present: send `attach` for owned panes and `focus`/`unfocus` on pane focus changes.

## 7. Live-process safety (hard rule, verbatim from the build prompt)

"Tests that demote, SIGTERM, hibernate, or resume sessions may only touch `claude` processes the test itself started, in scratch dirs under `$TMPDIR/ccterm-test/`. The user's real sessions may only be READ (pid, RSS, CPU). Every signal-sending code path takes an explicit pid allowlist in test mode; add a unit test proving a pid outside the allowlist is never signalled."

Throwaway sessions: `claude -p "reply with OK" --model haiku --session-id <uuid>` in a scratch dir under `$TMPDIR/ccterm-test/`, then an interactive `claude --resume <uuid>` in a PTY (e.g. `script -q /dev/null claude --resume <uuid>` or the app pane). No further prompts. A new scratch dir may show the folder-trust dialog; the process is alive regardless, which is all governing needs. Every test script installs a `trap` that kills the processes it started.

Coexisting job: `com.hotingyuen.claude-cpu-watcher` sums CPU of all `/claude` processes every 120 s and runs a cleanup script after 10 min above 80%. A large test fleet can add to that sum; keep fleets idle and short-lived.

## 8. Done-contracts

**M3 App shell** (app lane)
- `xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test` green.
- One pane runs `claude` in a chosen project dir; keyboard, paste, resize work. Screenshot `docs/screens/m3-pane.png`.
- Sidebar shows every entry of `claude agents --json`, grouped by cwd, with state and RSS; row count equals `claude agents --json | jq length` at test time. Screenshot `docs/screens/m3-sidebar.png`.
- Clicking a hibernated / not-open session opens a pane running `claude --resume <id>` in its cwd.
- 8 panes open: app RSS (ClaudeTerm process only) < 150 MB, measured with `ps -o rss= -p <app pid>`.
- Tests: JSON decoding of both agent shapes; grouping by project; argv builder rejects non-UUID ids.

**M4 Persistence** (app lane)
- Layout file written on change; quit + relaunch restores every pane; the focused pane runs `claude --resume <id>` in its cwd and transcript history is visible (screenshot `docs/screens/m4-restored.png`). Unfocused restored panes spawn no process until focused (`pgrep -f "resume <id>"` empty).
- Reboot survival argued from on-disk state (layout file + transcripts).
- Tests: layout round-trip; corrupt file recovery; lazy restore (no spawn until focus).

**M1 ccgovd index + metrics** (daemon lane)
- `swift build` and `swift test` green in `ccgovd/` (and `Protocol/`).
- `ccgovd status` lists every interactive and background session; RSS total within 5% of `ps -o rss=` summed over the same pids (claude + descendants). Proof: both numbers printed.
- SQLite store persists sessions across daemon restarts.
- Tests: agents JSON decode (both shapes); tree aggregation on a synthetic process table; store upsert/hibernated-row retention.

**M2 Governor** (daemon lane)
- demote/restore on a throwaway session verified with `getpriority(PRIO_DARWIN_PROCESS)` for every pid in its tree (and `ps -o pri` before/after as a second view).
- Hibernate then resume a throwaway session: transcript `<sessionId>.jsonl` still exists, and `claude -p --resume <id> --model haiku "what did I ask first?"` answers with the first prompt.
- Hibernate skips pinned and sessions with a shell descendant; threshold is honoured (tests fail if the threshold logic changes).
- SignalGate unit test: a pid outside the allowlist is never signalled; a pid whose start time changed is never signalled.
- Socket: 0600 file in a 0700 dir; malformed / oversize input handled.
- `launchd/com.hotingyuen.ccgovd.plist` + `make install-daemon` exist; nothing is loaded.
- Hook snippet + install README in `ccgovd/hooks/`; `~/.claude/settings.json` untouched.

**Integration** (main session): sidebar uses the socket when present (row count still matches), falls back to polling when the daemon is stopped.

**Memory target**: throwaway fleet of 8 idle sessions; one governor cycle (`--govern --idle-seconds <small> --scope-cwd-prefix $TMPDIR/ccterm-test --allow-pids <fleet>`); fleet RSS (claude + children) drops >= 40%. If missed, M5.
