# ccgovd hooks (opt-in)

`ccgovd hook` reads the Claude Code hook JSON on stdin and forwards it to the daemon socket. It always exits 0 within about one second, also when the daemon is down. The daemon uses the events to raise a session's last-activity time. Nothing here is installed automatically.

## Install

1. Install the binary: `make install-daemon` (copies to `~/.local/bin/ccgovd`).
2. Merge the `hooks` object from `settings-snippet.json` into `~/.claude/settings.json`. If you already have entries under `SessionStart`, `SessionEnd`, or `Notification`, append the `{ "type": "command", ... }` item to the existing `hooks` array of that event instead of replacing it.
3. Restart Claude Code sessions (hooks load at session start).

## Check

With the daemon running, start a session and run `ccgovd status`; the session's activity time moves on each hook event. With the daemon stopped, `echo '{}' | ccgovd hook; echo $?` prints `0`.

## Remove

Delete the three `ccgovd hook` entries from `~/.claude/settings.json`.
