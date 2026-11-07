<p align="center"><img src="docs/assets/icon.png" width="128" alt="ClaudeTerm icon"></p>

# ClaudeTerm

A native macOS terminal for running many Claude Code sessions at once. It comes with a background daemon, `ccgovd`, that cuts their memory use.

![ClaudeTerm with demo sessions: sidebar sections, memory bars, a live pane](docs/screens/demo.png)

<sub>Screenshot uses throwaway demo sessions only.</sub>

## Why use it

- **All sessions in one window.** Every Claude Code session on the Mac is listed, including ones started in other terminals. Each one shows its state and memory use.
- **Nothing is lost when you quit or reboot.** The app saves which panes were open. On relaunch each pane comes back with `claude --resume <id>` in its folder, so the conversation is still there.
- **Less memory.** One idle session with its MCP children used 610 to 850 MB on this Mac. `ccgovd` shuts down sessions that have been idle a long time and resumes them when you click them. In a test with 8 idle throwaway sessions, one governor cycle took them from 1.51 GB to 0.
- **Relaunch is cheap.** Only the selected pane starts `claude` on launch. The others start when you open them.
- **Real terminal.** Panes run on libghostty, so keyboard input, paste and resize behave like Ghostty.

## Features

### App

| Feature | What it does |
|---|---|
| Session sidebar | Lists every session in four sections: *Needs you* (waiting on you), *Open here*, *Elsewhere* (live in another terminal), *Asleep* (hibernated, with how long). Sessions sharing a project collapse into one row with a count. |
| Memory at a glance | Each live row has a bar sized to its memory (`claude` plus all child processes); hover for the number. The toolbar shows total live memory, sessions asleep, and memory freed by hibernation since launch. |
| Daemon status | A dot in the toolbar: filled when connected to `ccgovd`, hollow when polling. |
| Row menu | Right-click: Open, Close Pane, Pin (never hibernate), Hibernate Now, Reveal Folder, Copy Resume Command. |
| Pane status strip | One line under the terminal: session, folder (click to reveal), memory, `bg` when demoted. |
| Notices | Short messages appear as a banner over the pane and clear after 6 s. Nothing blocks the window. |
| Panes | Each pane runs `claude` in a project folder. One pane is shown at a time; switch from the sidebar. With no pane open, the three most recent sessions are listed for one-click reopen. |
| New session | Toolbar `+` or Cmd-N asks for a folder and starts a new `claude` there. Cmd-Shift-W closes the pane. |
| Resume | Clicking a hibernated or closed session opens a pane that runs `claude --resume <id>`. |
| Layout persistence | Open panes, the selected pane and the window frame are saved on every change and restored on launch. A corrupt layout file is moved aside to `layout.json.bad`. |
| Daemon link | Reads sessions from the `ccgovd` socket when it is running. Otherwise it polls `claude agents --json` every 5 s, and reconnects to the daemon within about 10 s. |
| Duplicate guard | A session that is live in another terminal is not opened a second time. |

### Daemon (`ccgovd`)

| Feature | What it does |
|---|---|
| Index | Keeps a SQLite record of every session with memory and CPU per process tree. |
| `status` | Prints the session table. Totals matched `ps` within 0.4% in testing. |
| Demote (with `--govern`) | Moves sessions you are not looking at to background CPU priority after 60 s idle. Focus or new work restores them. |
| Hibernate (with `--govern`) | Shuts down sessions idle for 30 minutes (configurable) and frees all their memory. Pinned sessions and sessions running a shell command are skipped. |
| Hook | Optional Claude Code hook, `ccgovd hook`, reports activity as it happens. It always exits 0 within 1 s. |

### Safety

- The daemon is read-only unless started with `--govern`.
- Before sending any signal it checks that the process has the pid and start time it recorded, belongs to you, and is still part of that session's process tree.
- The socket is mode `0600` and checks the connecting user.
- Session ids must be UUIDs before they reach a command line.

## Performance

Measured on this Mac on 2026-11-07 (macOS 27.0.1, Claude Code 2.1.319), with idle throwaway sessions.

| | Host app, idle | 8 idle sessions | Total for 8 sessions |
|---|---|---|---|
| Terminal.app + `claude` | 55 MB | about 4.9 GB | about 5.0 GB |
| Claude desktop app | 1.7 GB | see note | 1.7 GB + sessions |
| ClaudeTerm | 80 MB (1 pane), under 150 MB (8 panes) | about 4.9 GB | about 5.0 GB |
| ClaudeTerm + `ccgovd --govern` | same | 0 after one governor cycle | under 150 MB + the session you are using |

- **Per session:** 4 idle throwaway sessions used 2,494,160 KB (about 610 MB each, `claude` plus MCP children). That cost is the same in any host, because every host runs the same `claude` process.
- **Hibernation:** 8 idle sessions went from 1,510,320 KB to 0 KB after one governor cycle. A second run went from 1,979,504 KB to 0 for 2 sessions. Clicking a sleeping session resumes it with its history.
- **Host overhead:** sum of RSS over each app's processes after 30 s idle. Terminal.app: 56,016 KB over 4 processes. Claude desktop app: 1,749,472 KB over 15 processes, with nothing open. ClaudeTerm: 80,944 KB with one pane.
- **Not measured:** how the Claude desktop app runs Claude Code sessions, so its per-session cost is not in the table. CPU use was not compared.

How to reproduce: `scripts/fleet.sh start 8`, then `scripts/fleet.sh rss`, then one `ccgovd run --govern --once --idle-seconds 1 --allow-pids <fleet pids> --scope-cwd-prefix "$TMPDIR/ccterm-test"`, then `scripts/fleet.sh rss` again, then `scripts/fleet.sh stop`.

## Requirements

- macOS 14 or later (built and tested on macOS 27).
- Xcode with Swift 6, and [xcodegen](https://github.com/yonaskolb/XcodeGen).
- Claude Code with `claude agents --json` (tested on 2.1.319).

## Build and run

```sh
cd App && xcodegen generate
xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test
open "$(xcodebuild -scheme ClaudeTerm -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR/{print $3}')/ClaudeTerm.app"
```

## Install the daemon

```sh
cd ccgovd
make install-daemon            # read-only: index and measure only
make install-daemon GOVERN=1   # also demote and hibernate
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hotingyuen.ccgovd.plist
ccgovd status
```

To enable the hook, follow `ccgovd/hooks/README.md`.

## Layout

| Path | Contents |
|---|---|
| `App/` | SwiftUI app, generated by xcodegen from `project.yml`. |
| `ccgovd/` | SwiftPM package: `CCGovCore` library and `ccgovd` executable. |
| `Protocol/` | Shared socket message types. |
| `scripts/` | Throwaway-session fleet used in tests. |
| `docs/` | Research, design proposal (`docs/design.md`), screenshots. |

## Limits

- A pane does not keep running while the app is closed. It comes back through `--resume` (live survival is planned for v2).
- No split panes or tabs. The UI follows `docs/design.md`.
- macOS only.
