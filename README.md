<p align="center"><img src="docs/assets/icon.png" width="128" alt="ClaudeTerm icon"></p>

# ClaudeTerm

A native macOS terminal for running many Claude Code sessions. It comes with `ccgovd`, a daemon that puts idle sessions to sleep so they stop using memory.

![ClaudeTerm](docs/screens/demo.png)

## Why

- **One window.** Every Claude Code session on the Mac, grouped by status, with live memory.
- **Nothing lost.** Quit or reboot, and each pane comes back with `claude --resume`.
- **Less memory.** 8 idle sessions went from 1.5 GB to 0 after one daemon cycle.
- **Real terminal.** Panes run on libghostty.

## Features

| App | Daemon (`ccgovd`) |
|---|---|
| Sidebar sections: *Needs you*, *Open here*, *Elsewhere*, *Asleep* | Session index with memory and CPU per process tree |
| Memory bar per session, totals in the toolbar | Moves unfocused idle sessions to background priority |
| Usage tab: quota and cost (CodexBar, ccusage) | Hibernates sessions idle for 30 min, resumes them on click |
| Right-click: pin, hibernate, reveal, copy resume command | Read-only unless started with `--govern` |
| Layout restored on launch, panes start lazily | Checks a process's identity before signalling it |

## Performance

Idle sessions, measured on 2026-11-07.

| | App | 8 idle sessions |
|---|---|---|
| Terminal.app | 56 MB | ~4.9 GB |
| Claude desktop app | 1.7 GB | not measured |
| ClaudeTerm | 81 MB | ~4.9 GB |
| ClaudeTerm + `ccgovd --govern` | 81 MB | **0** |

## Build

Needs macOS 14+, Xcode with Swift 6, `xcodegen`, Claude Code 2.1.319+.

```sh
cd App && xcodegen generate
xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build
```

## Daemon

```sh
cd ccgovd
make install-daemon            # read-only
make install-daemon GOVERN=1   # also demote and hibernate
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hotingyuen.ccgovd.plist
```

Hook setup: [`ccgovd/hooks/README.md`](ccgovd/hooks/README.md). Design notes: [`docs/design.md`](docs/design.md).
