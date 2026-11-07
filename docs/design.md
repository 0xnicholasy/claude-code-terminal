# ClaudeTerm redesign proposal

Baseline: `docs/screens/integration-sidebar.png`. The current window is a stock `NavigationSplitView`: a sidebar of sessions grouped by project, a single pane area, and two toolbar buttons (new session, close pane). It works, but it hides the two things the app exists for, memory and session state, and it treats every session the same.

## Problems in the current design

1. **Repeated names.** Most projects hold one session, so each group header ("omen", "unasunder") is followed by a row with nearly the same text ("omen-24", "unasunder-70"). Half the sidebar height is spent saying each name twice.
2. **Memory is a column of small grey numbers.** The app's main promise, less RAM, has no total and no visual weight. A 1.7 GB session looks the same as a 225 MB one.
3. **State reads as noise.** Every row repeats the word "idle" or "blocked" next to an icon that already says it. Blocked sessions (waiting on you) are the ones that need action, but they are not separated from the rest.
4. **No sense of which sessions are in this app.** Sessions open in a pane, sessions in other terminals, and hibernated sessions all look alike until you click one and get an alert.
5. **Modal alerts.** Clicking a session that lives in another terminal opens a blocking alert. That is a status, not an error.
6. **Empty pane area.** With no pane selected, most of the window is an empty grey rectangle with one line of text.

## Proposed layout

```
+--------------------------------------------------------------------------+
| (traffic lights)   [ 6.2 GB live · 3 asleep · 1.9 GB freed ]   [+] [:]   |
+----------------------+---------------------------------------------------+
| NEEDS YOU            |                                                   |
|  ! test /office  mod |                                                   |
|  ! ADHD decision wat |              terminal pane (libghostty)           |
|                      |                                                   |
| OPEN HERE            |                                                   |
|  > claude-code-ter.. |                                                   |
|    proj8        ===  |                                                   |
|                      |                                                   |
| ELSEWHERE            |                                                   |
|    video-studio ==== |                                                   |
|    omen    2  ==     |                                                   |
|                      +---------------------------------------------------+
| ASLEEP               | claude-code-terminal · ~/Desktop/... · 551 MB · bg |
|  ) unasunder         |                                                   |
+----------------------+---------------------------------------------------+
```

### Sidebar

- **Group by what you can do, not by folder.** Four sections in fixed order: *Needs you* (blocked), *Open here* (panes in this app), *Elsewhere* (live in another terminal), *Asleep* (hibernated). Folder becomes secondary text on the row.
- **One line per session.** Show the session name. Show the project only when it differs from the name. When several sessions share a project, collapse them into one row with a count ("omen 2") that expands on click.
- **Memory as a bar.** Each live row ends in a thin horizontal bar scaled to the largest session, with the number on hover. Large sessions are visible at a glance without reading digits.
- **State by colour and position only.** Drop the "idle"/"blocked" words. Blocked rows already sit under *Needs you*; running rows get a small animated dot; demoted rows get a dimmed name.
- **Asleep rows are dimmed** and show how long they have slept ("2 h") instead of a dash for memory.

### Toolbar

- **Memory summary as the title.** Replace the "ClaudeTerm" title with three numbers: live RSS across all sessions, number asleep, and memory freed by hibernation since the daemon started. This is the one place the app proves it is working.
- **Daemon status** as a small dot inside that summary: filled when connected to `ccgovd`, hollow when the app is polling `claude agents --json`.
- Keep the new-session button. Move close-pane to the pane's own context menu and Cmd-W.

### Pane area

- **Status strip under the terminal**, one line: session name, cwd (shortened), live RSS, and priority (`bg` when demoted). Click the cwd to reveal it in Finder.
- **Empty state lists the three most recent sessions** as large rows to reopen, plus "New session in folder...". One click instead of reading the sidebar.

### Non-modal notices

- Replace alerts with an inline banner at the top of the pane area that dismisses itself after 6 s. Example: "test /office is open in another terminal (pid 26809)."

### Row actions

- Right-click a row: Open, Pin (never hibernate), Hibernate now, Reveal folder, Copy `claude --resume` command. Pin shows a small pin glyph on the row.

## Visual rules

- Dark-first, using system materials (`.sidebar`, `.windowBackground`) so light mode works for free.
- One accent colour, amber `#F5A524`, matching the app icon. It is used only for *Needs you* rows and the running dot.
- Monospaced digits for every number.
- Excluded on purpose: cream or beige backgrounds, gradient headers, pill-shaped buttons, numbered section labels, decorative icons beside section headers, emoji, and extra descriptive subtitles under headers.

## Build order (each step ships alone)

1. Status-based sections and one-line rows (`Views.swift`, `AgentsModel.swift` grouping). About 2 hours.
2. Toolbar memory summary and daemon dot (needs `totals` from the daemon socket; the polling path sums rows). About 1 hour.
3. Inline banner in place of alerts. About 30 minutes.
4. Memory bars, pane status strip, empty-state recents. About 2 hours.
5. Row context menu wired to the daemon's `pin`, `hibernate` and `resume` commands. About 1 hour.
