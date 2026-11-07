# Native Claude Code terminal: research

Date: 2026-11-07. Claude Code 2.1.319, macOS (Darwin 27), 18 GB RAM, Ghostty.
All external sources are from 2026. Items not confirmed are listed at the end.

## 1. What this machine actually uses (measured 2026-11-07)

| Consumer | RSS | Notes |
|---|---|---|
| 8 `claude` processes | 1.38 GB (avg 172 MB, max 330 MB) | 4 of them idle for 2 h to 1.7 days |
| Their children (MCP servers, shells) | ~300 MB | 3 local stdio MCPs per session: jev-browser, discord (`npm exec`), lcu. github + linear are HTTP, no process |
| `ccusage` from `~/.claude/statusline.sh` | 1.1 to 1.3 GB per run, every 5 min | Parses 7.3 GB of JSONL in `~/.claude/projects` (5,624 files, 194 projects) |
| Chrome (all helpers) | 1.23 GB | Shared real Chrome, not one per session |
| Ghostty | 43 MB | The terminal itself is not the problem |

Conclusions:
- The terminal emulator costs ~43 MB. Replacing it saves nothing measurable on its own.
- The cost is per-session processes that stay alive while idle, and the statusline `ccusage` job.
- Subagents run inside the parent `claude` process on macOS (verified: no extra `claude` PID while two research subagents ran).
- MCP fan-out is small on this setup (~40 MB/session) but scales N sessions x M stdio servers.

## 2. Resource sinks reported in 2026 (ranked)

1. **Stdio MCP fan-out.** Every session starts every configured stdio server. anthropics/claude-code#82952 (2026-07-31): 5 sessions, 46 node MCP helpers, 4.86 GB. #45880 (2026-04-09): 15 Ghostty tabs x 34 MCP servers led to OOM and a kernel panic. Only HTTP/SSE servers connect lazily ([MCP docs](https://code.claude.com/docs/en/mcp)).
2. **Leaks in the `claude` binary**, version-specific: #32892 (2026-03-10, v2.1.71) ArrayBuffer growth; later reports through June 2026. Mitigation: restart long-lived sessions; stay current.
3. **Idle TUI CPU.** #69251 (2026-06-18) idle session at ~2.4 cores from the Ink render loop; #81353 (2026-07-26) idle spin episodes. Closed not_planned.
4. **Browser automation.** Claude in Chrome uses your real Chrome; concurrent sessions interfere (#87767, 2026-08-18, closed not_planned). Playwright-style MCPs start one browser per session.

Official knobs ([env vars](https://code.claude.com/docs/en/env-vars)): `ENABLE_TOOL_SEARCH`, `CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`, `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`, `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS`, `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT`, rendering flags (`CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN`, etc.).

## 3. What Claude Code already provides for persistence

| Feature | Use for this app |
|---|---|
| Transcripts `~/.claude/projects/<cwd>/<session-id>.jsonl` | Source of truth for resume. Format is internal and changes between versions: read metadata only |
| `claude --resume <id>` | Works from any directory. Restores history, model, permission mode. Not `--mcp-config` / `--add-dir` |
| Agent view: `claude agents`, `--bg` | Supervisor daemon, state in `~/.claude/jobs/`, `~/.claude/daemon/roster.json`. Survives sleep, not shutdown. Reaps idle unattached sessions after ~1 h ([agent-view](https://code.claude.com/docs/en/agent-view.md)) |
| `claude agents --json` | **Verified locally:** returns all active sessions, interactive (with `pid`) and background, with `cwd`, `sessionId`, `name`, `state` (e.g. `blocked`). No TTY needed. This is the session index the app should read |
| Hooks: `SessionStart`, `SessionEnd`, `Notification` | Push events (`session_id`, `transcript_path`, `cwd`) into the app instead of polling |
| `--cloud` | Only option that survives a laptop shutdown while running |

Each Claude surface (CLI, Desktop, web, VS Code) keeps its own session list.

## 4. Existing tools (2026)

| Tool | Persistence | Stack / license | Status |
|---|---|---|---|
| [cmux](https://github.com/manaflow-ai/cmux) | Restores layout, cwd, scrollback; re-runs `claude --resume <id>` via hooks. No live process survival | Swift/AppKit + libghostty, GPL-3.0 | Active, 28.7k stars |
| [herdr](https://github.com/herdrdev/herdr) | Background server survives client close; resumes agents after restart | Rust, Apache-2.0 | Active |
| [Vesta](https://github.com/vestaterm/Vesta) | Daemon keeps shells alive past app quit | Swift + GhosttyKit, MIT | Small, last push 2026-08-31 |
| Claude Squad | tmux per task | Go, AGPL-3.0 | Active |
| opcode (ex-Claudia) | Reads `~/.claude/projects` | Tauri, AGPL-3.0 | Active |
| Warp | Closing Warp ends the session | Rust | Active |
| Crystal, Vibe Kanban | — | — | Deprecated / company shut down |

No tool measures or limits resource use. None reads Claude's own `claude agents --json` index; none survives a reboot with running processes.

## 5. Terminal stack options

| Option | Status 2026 | Memory | License |
|---|---|---|---|
| **libghostty via [libghostty-spm](https://github.com/Lakr233/libghostty-spm)** (`GhosttyKit`, `GhosttyTerminal` SwiftUI/AppKit views, Metal) | Pre-1.0, weekly releases, one more ABI break expected before 1.0 ([Ghostty 1.4.0 notes](https://ghostty.org/docs/install/release-notes/1-4-0), 2026-10-27). Used by cmux, Vesta | Empty surface 16 KiB; idle scrollback compressed 70-90%; hidden tabs release GPU memory | MIT |
| SwiftTerm | Mature, active | Not published | MIT (unconfirmed) |
| xterm.js in Tauri/Electron | Mature; WebGL context limits at 4-6 panes in Tauri/WebKit | ~200 MB webview baseline + ~8 MB/pane | MIT |
| alacritty_terminal / wezterm-term | Model-only, need own renderer + FFI | — | Apache-2.0 / MIT |

Pick: libghostty-spm. Same renderer you use today, smallest footprint, MIT.

## 6. Where the savings actually come from

| Lever | Expected saving here | Needs a new terminal? |
|---|---|---|
| Fix statusline `ccusage` (cache, incremental, or drop) | 1.1-1.3 GB spike every 5 min | No |
| Hibernate idle sessions: kill, then `claude --resume <id>` on focus | ~210 MB per idle session (claude + MCPs). 4 idle now = ~850 MB | No (a daemon can do it); a UI makes it painless |
| Demote unfocused sessions: `taskpolicy -b -p <pid>`, restore with `-B` | Idle CPU burn moves to E-cores | No |
| Share stdio MCPs as one HTTP daemon each | ~40 MB/session now; large if you add MCPs | No |
| One shared browser over CDP with per-session tabs | Avoids N browsers | No |

The native terminal's own value is UI: one window, all projects, hibernated sessions shown as resumable, live per-session RAM/CPU.

## Unconfirmed

- Subagent process model on other platforms (Windows reports show separate processes). Verified in-process on this Mac only.
- `claude` baseline RSS: issues claim 300-500 MB; measured 150-330 MB here.
- SwiftTerm license and release years.
- cmux docs site had a TLS error; restore mechanism taken from the repo README and search snippets.
- Whether `taskpolicy -m` (memory limit) works on a running process (man page lists it at launch only).
- libghostty-spm latest release date (release list empty on the page; README says weekly).
