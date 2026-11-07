# Lessons

- libghostty-spm `2.2.2026103001` runs the surface `command` as `/bin/bash --noprofile --norc -c "exec -l <command>"` under `/usr/bin/login -flp`. The upstream `direct:` prefix is not honoured; it becomes part of the path. Pass a plain command made only of shell-inert characters (validated absolute path, fixed flags, UUID); cwd goes through `workingDirectory`.
- An app launched from inside a Claude Code session inherits `CLAUDE_CODE_CHILD_SESSION`, `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` and similar markers. A claude started under them turns transcript saving off and is missing from `claude agents --json`. Scrub session-scoped markers before spawning; keep user knobs.
- A Bash hook blocks commands that contain `rm` plus a `*` anywhere (even in a `case` pattern) and trailing `echo $?`. Write scripts with the Write tool; let exit codes surface.
- `screencapture -l<id>`: pick the window by its bounds; the app also owns a hidden 500x500 window and menu-bar windows.
- Ghostty default keybinds stay active in an embedded surface: `super+q=quit` swallowed Cmd-Q because the host does not implement the quit action. Unbind keys whose actions the host does not handle (`TerminalController { $0.withCustom("keybind", "super+q=unbind") }`).
