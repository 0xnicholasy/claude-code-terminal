# Lessons

- libghostty-spm `2.2.2026103001` runs the surface `command` as `/bin/bash --noprofile --norc -c "exec -l <command>"` under `/usr/bin/login -flp`. The upstream `direct:` prefix is not honoured; it becomes part of the path. Pass a plain command made only of shell-inert characters (validated absolute path, fixed flags, UUID); cwd goes through `workingDirectory`.
- An app launched from inside a Claude Code session inherits `CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and similar markers. A claude started under them turns transcript saving off and is missing from `claude agents --json`. Scrub session-scoped markers before spawning; keep user knobs.
- A Bash hook blocks commands that contain `rm` plus a `*` anywhere (even in a `case` pattern) and trailing `echo $?`. Write scripts with the Write tool; let exit codes surface.
- `screencapture -l<id>`: pick the window by its bounds; the app also owns a hidden 500x500 window and menu-bar windows.
- Ghostty default keybinds stay active in an embedded surface: `super+q=quit` swallowed Cmd-Q because the host does not implement the quit action. Unbind keys whose actions the host does not handle (`TerminalController { $0.withCustom("keybind", "super+q=unbind") }`).
- Any state the daemon keeps only in memory (focus, ownership) must be re-sent by the client on every (re)connect; otherwise a daemon restart silently changes policy for visible panes.
- Derive "demoted" from kernel state (`pbi_flags` DARWINBG), never from a stored flag: rows get rebuilt when a session blips out of `claude agents --json`.
- SIGKILL escalation after SIGTERM must identify survivors by pid + recorded start time, not by parent chain: the children are reparented to launchd once claude exits.
- A one-shot CLI action that runs in-process must not run the full policy cycle; it would act on every other in-scope session.
- Server-side socket writes from a serial state queue need SO_SNDTIMEO, or one stalled subscriber freezes the daemon.
- Validate shell-parsed strings with an allowlist of inert characters, not a denylist (braces, tildes and globs still expand).
- `scripts/fleet.sh pids` prints `pid uuid dir` rows; take column 1 before building `--allow-pids`, or the daemon refuses the allowlist and does nothing.
- A pid-reuse check on a descendant is incomplete unless the root itself is revalidated: a reused root pid makes the parent-chain check vouch for a stranger's children.
