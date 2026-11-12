# Claude Code features, round 2

ultraplan: claude-code-features | branch: feat/claude-code-features | base: main | tag: pre-claude-code-features-main | created: 2026-11-12
Status: ACTIVE
Progress: 4/25 done

## Goal
Make the ClaudeTerm sidebar show what each open session is doing and how full its context is (M6). Let the user answer a permission prompt from the sidebar or from the macOS notification without focusing the pane (M7). Cmd-Shift-T starts a session in a new git worktree (M8). A read-only Config tab lists MCP servers, skills, agents and hooks for the selected project (M9).

## Constraints
- Existing features keep working. GATE must be green after every todo. GATE has a 60 s minimum timeout; on a timeout, retry once with a longer one.
  - GATE = `cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/App && xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test` (run it in the todo's working copy: replace the path with the worktree path in worktree mode)
  - BUILD = `cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal && scripts/build-app.sh` (Release app at `build/ClaudeTerm.app`; same working-copy rule)
  - FOCUSED = `cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/App && xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' test -only-testing:ClaudeTermTests/<TestClass>`
  - Landing todos also run `cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/Protocol && swift test` and `cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/ccgovd && swift build && swift test`. No todo here edits those packages; the runs only confirm that.
- No todo edits `App/project.yml`. Sources and tests are picked up by directory, and `xcodegen generate` inside GATE adds new files. No release or version bump inside any todo (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` stay at 0.1.12 / 12); releases are separate.
- No emoji in code. Match the module's existing layout: one feature per file, pure logic in an `enum` with static functions, and side effects injected as closures on `WorkspaceModel` (see `paneProcess`, `attention` in `Workspace.swift:122-152`). Icons are SF Symbols, as in the existing views.
- The transcript format is undocumented. Every jsonl parser decodes line by line and skips unknown or garbled lines (`try?` per line, as in `TranscriptReplies.parse`, `Markdown.swift:158-194`). A bad line never fails the whole file.
- Polling cost:
  - Read transcripts only for open panes with a running process (`Pane.hasProcess`). Hibernated and sleeping sessions are never read.
  - The status parser tails a small window (target 256 KB, not the 3 MB `RepliesModel` uses).
  - Measure app CPU with 8 open panes before (T02) and after (T07) M6.
- Text into a pane goes on libghostty's key path only: `TerminalViewState.sendKey(_:modifiers:)`, `build/SourcePackages/checkouts/libghostty-spm/Sources/GhosttyTerminal/State/TerminalViewState.swift:143-159`. Never use `paste(text:)` (lines 130-141). It is a bracketed paste, so a `1` or an Esc sent that way would land as pasted text.
- Live checks run from a terminal outside ClaudeTerm (Terminal.app), after quitting any installed ClaudeTerm: both copies share `layout.json` and ccgovd. A session running inside a ClaudeTerm pane must not quit or relaunch that ClaudeTerm. Screenshots: `screencapture -x <working copy>/build/live-<milestone>.png`. Screen capture was refused in-session on 2026-11-08 (`tasks/todo.md:87` on main). If it is refused again, the live-check todo stays `todo`, lists the commands for the owner, and its milestone is reported as "tests pass, not validated live".
- Config tab (M9): never open `.env` files, never decode settings `env` values, never show MCP command arguments or URLs (they can carry tokens).
- The main checkout has uncommitted edits (`SessionSource.swift`, `Usage.swift`, `UsageView.swift`, `UsageTests.swift`, `tasks/*.md`) from another change. Never touch them; while they exist, `/implement` runs in worktree mode. No todo here touches `SessionSource.swift`, `Usage.swift` or `UsageView.swift`.

## Decisions
- D1 Land per milestone. After each milestone's live check, a landing todo opens a PR `feat/claude-code-features` -> `main` (merge commit). The owner merges it. No later todo `needs` a landing todo. (owner, 2026-11-12)
- D2 Closing a session never deletes its worktree (M8). (owner, 2026-11-12)
- D3 Config browser is read-only; settings `env` values masked (here: never decoded); `.env` files never read. (owner, 2026-11-12)
- D4 Each milestone ends with a live-check todo, with screenshots of the running app for UI checks. (owner, 2026-11-12)
- D5 The branch was cut from `origin/main` at `fc9999a` (v0.1.12). The uncommitted Usage/SessionSource edits in the main checkout are a separate change and out of scope; `main` is merged into the feature branch per `/implement` step 2 when it moves. (orchestrator, 2026-11-12)
- D6 If an earlier milestone's PR is still unmerged when the next landing todo runs, that todo comments on the open PR (listing the new milestone) instead of opening a second one. | assumed, confirm by T08
- D7 Claude Code 2.1.322 permission prompt: `1` (`TerminalKey.digit1`) approves once and Esc (`TerminalKey.escape`) denies. | confirmed by T01 (2026-11-12)
- D8 The app passes no model flag at launch (`ClaudeCommand.swift:27-33`), so the 1M window must be detected from the transcript. If no field marks it, fall back to 1M once context tokens exceed 200K. | confirmed by T02 (2026-11-12): no field marks it
- D9 CPU budget: with 8 idle open panes, M6 may add at most 1.0 percentage point to the app's average CPU over 60 s. | assumed, confirm by T07
- D10 Allow/Deny is offered only when the transcript has exactly one pending main-thread `tool_use` and its tool is not `AskUserQuestion`, `ExitPlanMode`, `Task` or `Agent`. Those have other menus, or the prompt belongs to a subagent. | assumed, confirm by T12
- D11 `claude -w <name>` combines with `--session-id <uuid>`, creates `<repo>/.claude/worktrees/<name>`, and the session's cwd is the worktree path. The pane records that path as its cwd, so restore and `--resume` run there. | confirmed by T03 (2026-11-12), with the trust and auto-removal notes in its Log entry
- D12 MCP rows show server name, scope and health status only. Scope comes from server names in `<project>/.mcp.json` and `~/.claude.json` (only the `mcpServers` key names are decoded) and from the `plugin:` prefix; anything else shows "unknown". | assumed, confirm by T21
- D13 Plugin skills are found under `~/.claude/plugins/**/skills/*/SKILL.md`. | assumed, confirm by T20
- D14 Clicking a Config row reveals its file in Finder (`NSWorkspace.activateFileViewerSelecting`). MCP rows have no click action. | assumed, confirm by T23

## Todos

### T01 Spike: send keys to a hidden pane and pin the prompt key mapping
- status: done (#2, 2026-11-12)
- needs: none
- size: S
- scope: On a scratch stash, not committed:
  - Make `Pane.terminal` reachable.
  - Add a temporary Debug menu item that calls `sendKey(.digit1)` / `sendKey(.escape)` on a pane that is not selected.
  - Trigger a Bash permission prompt (`touch /tmp/ct-spike`) in that pane on Claude Code 2.1.322.

  Record in Log:
  - (a) whether a hidden pane (`isSurfaceVisible = false`, `Views.swift:690-693`; mounted at opacity 0 by `PaneArea`, `Views.swift:496-499`) still has a surface, i.e. `sendKey` returns true
  - (b) which key approves and which denies (D7), and what `2` does
  - (c) whether the pending `tool_use` line is already in the jsonl while the prompt is on screen (`tail -n 3 <transcript> | cut -c1-300`)
  - (d) whether a restored pane that was never selected has no process (`Pane.hasProcess` false), so it gets no buttons
- files: `App/Sources/ClaudeTerm/Workspace.swift:17,84-99` (Pane.terminal, viewState), `App/Sources/ClaudeTerm/Views.swift:486-508,675-694` (PaneArea, PaneView), `App/Sources/ClaudeTerm/ClaudeTermApp.swift:79-113` (temporary Go menu item), `build/SourcePackages/checkouts/libghostty-spm/Sources/GhosttyTerminal/State/TerminalViewState.swift:130-159`, `.../Surface/TerminalKey.swift:26,149`
- done when: Log has answers (a)-(d) with the observed evidence. The spike code is stashed or dropped, and `git status` shows no spike files.
  - If (a) or (b) fails, T09-T13 move to Backlog, and their dependents are re-pointed: T15 needs T14, T16 needs T15, T17 needs T06 and T16.
- verify: `git status --short` in the working copy (no spike files), then GATE

### T02 Spike: transcript fields, 1M signal, CPU baseline
- status: done (#3, 2026-11-12)
- needs: none
- size: S
- scope: Read the last 200 lines of one normal session's transcript and one 1M-context session's transcript under `~/.claude/projects` and record:
  - the exact field names for `tool_use` (id, name, input), `tool_result` (`tool_use_id`) and `message.usage` (input, cache read, cache creation tokens), and `message.model`
  - how sidechain lines are marked (`isSidechain`) and whether subagent lines live in a separate file
  - whether any field marks the 1M window (D8)

  Write 6-8 hand-made, scrubbed fixture lines (no real prompt text, paths or command output) into the Log for T04. Then build (BUILD), open 8 idle panes, and record the baseline CPU.
- files: none in the repo (Log entry only)
- done when: Log lists the field names, the 1M answer (field name, or "none -> tokens > 200K fallback"), the fixture lines, and the baseline average CPU % for 8 idle panes.
- verify: BUILD, `open <working copy>/build/ClaudeTerm.app`, open 8 panes, wait 60 s, then `top -l 13 -s 5 -pid "$(pgrep -nx ClaudeTerm)" -stats cpu | grep -E '^[0-9.]+$' | tail -n 12 | awk '{s+=$1} END {printf "avg %.1f%%\n", s/NR}'`

### T03 Spike: `claude -w` behaviour on 2.1.322
- status: done (#4, 2026-11-12)
- needs: none
- size: S
- scope: In a scratch git repo (`/tmp/ct-wt-spike`, `git init` plus one commit), run `claude --session-id <uuidgen lowercased> -w spike-a` and record in Log:
  - the worktree path created and the branch name it gets
  - whether `--session-id` is honoured with `-w`, i.e. the transcript is `<id>.jsonl`, and which `~/.claude/projects/<dir>` it lands in
  - the cwd that `claude agents --json` (or ccgovd) reports for it
  - whether `claude --resume <id>` from the worktree folder resumes it
  - which name characters `-w` accepts or rejects (try `a.b`, `a_b`, `a b`, `-x`)
  - what `-w` does when run from a subfolder of the repo
- files: none in the repo (Log entry only)
- done when: Log answers each point and confirms or corrects D11.
- verify: `git -C /tmp/ct-wt-spike worktree list` shows the new worktree; `ls ~/.claude/projects/*/<id>.jsonl` finds the transcript

### T04 Add TranscriptStatus parser
- status: done (#PR, 2026-11-12)
- needs: T02
- size: M
- scope: New `Transcript.swift` with `struct TranscriptStatus: Equatable` and `static func parse(_ data: Data) -> TranscriptStatus`, using its own private `Decodable` line type. The fields T02 found are added there; `TranscriptReplies.Line` stays private and unchanged.
  - Output `pending: [PendingTool]` (id, name, summary) = main-thread `tool_use` blocks with no later matching `tool_result`, cleared by a later real user prompt.
  - Output `activity` = summary of the last pending tool, or nil.
  - Output `contextTokens` = input + cache_read + cache_creation of the last assistant `usage`; `model` = last `message.model`.
  - Summary rules:
    - `Edit` / `Write` / `Read` / `NotebookEdit` -> name + file basename
    - `Bash` -> `Bash: ` + the command's first line, cut to 60 chars
    - `Task` / `Agent` -> `Task: ` + description
    - `mcp__server__tool` -> `server: tool`
    - else -> tool name
  - Add `contextLimit(model:tokens:)` (200K, or 1M per D8) and `ContextLevel.of(fraction)` (normal, amber >= 0.70, red >= 0.85).
- files: new `App/Sources/ClaudeTerm/Transcript.swift`; new `App/Tests/ClaudeTermTests/TranscriptTests.swift`; read-only reuse of `ClaudeUsageParser.date` (`Usage.swift:205`)
- done when: TranscriptTests cover:
  - a pending tool_use
  - a completed tool_use
  - two parallel pending tool_uses
  - a pending one cleared by a new prompt
  - a sidechain tool_use that is ignored
  - the usage sum
  - the 200K and 1M limits
  - the 70 % / 85 % level edges
  - a garbled line skipped while the rest still parses
  - a truncated first line from `tail`

  Each test fails if its rule is removed.
- verify: FOCUSED with `<TestClass>` = `TranscriptTests`, then GATE

### T05 Add TranscriptStatusModel polling open panes
- status: todo
- needs: T04
- size: M
- scope: `@MainActor final class TranscriptStatusModel: ObservableObject` in `Transcript.swift`, publishing `statuses: [String: TranscriptStatus]` keyed by session id.
  - Every 2 s it checks the mtime of each transcript for the panes passed in (`panes.filter(\.hasProcess)`) and re-parses only files that changed, via `TranscriptReplies.tail(_:maxBytes: 256 * 1024)` (`Markdown.swift:206`).
  - Paths are resolved once per id with `TranscriptReplies.transcriptPath` (`Markdown.swift:198`), off the main thread.
  - Ids no longer open are dropped.
  - Path lookup, mtime and read are injected closures, so tests run without the file system.
  - Created in `Bootstrap`, so the M7 notifier can reach it, and handed to `ContentView`. Under test it is inert (`Bootstrap.isUnderTest`).
- files: `App/Sources/ClaudeTerm/Transcript.swift`; `App/Sources/ClaudeTerm/ClaudeTermApp.swift:6-16,132-171` (StateObject, Bootstrap); `App/Sources/ClaudeTerm/Views.swift:13-20` (ContentView parameter); `App/Tests/ClaudeTermTests/TranscriptTests.swift`
- done when: tests show:
  - an unchanged mtime does not re-read
  - a changed mtime re-parses
  - a pane without a process is never read
  - a closed pane's status is removed

  The app builds with the model wired in.
- verify: FOCUSED with `<TestClass>` = `TranscriptTests`, then GATE

### T06 Show activity line and context ring in the sidebar row
- status: todo
- needs: T05
- size: M
- scope: `SessionRow` gets the session's `TranscriptStatus?`, passed down from `SidebarView`.
  - Second line: the activity, one line, truncated, `Palette.textTertiary`, only while the state is `.running`. The waiting line at `Views.swift:351-353` stays.
  - Right side: a small `ContextRing` showing the context %, coloured by `ContextLevel` (amber, red from `Palette`). Shown for open panes with a status, always visible, not only on hover.
  - Help text adds `Context: 132K of 200K (66%)` via `Formatting.tokens` (`Sidebar.swift:150`).
  - Row height grows only when the second line shows.
- files: `App/Sources/ClaudeTerm/Views.swift:207-273` (SidebarView pass-through), `329-420` (SessionRow), `156-190` (Palette colours if new ones are needed)
- done when: the app builds; the ring and line render in an Xcode preview or the running app; GATE is green. No row reorders when the activity changes.
- verify: GATE, then BUILD

### T07 Live check M6: activity line, context ring, CPU
- status: todo
- needs: T06
- size: S
- scope: Run the BUILD app.
  - In one pane, ask claude to run `sleep 20 && echo done`. Its row must read `Bash: sleep 20 && echo done` within 4 s and clear within 4 s after it finishes.
  - Compare the ring % with `/context` in the same session (within 3 points).
  - Repeat the T02 CPU measurement with the same 8 panes.
- files: none
- done when:
  - the screenshot `build/live-m6.png` shows the activity line and ring
  - Log has the before/after CPU numbers within D9
  - Log has the ring-vs-`/context` comparison
- verify: BUILD; `screencapture -x <working copy>/build/live-m6.png`; the T02 `top` command

### T08 Land M6
- status: todo
- needs: T07
- size: S
- scope: Push the branch and open the PR `feat/claude-code-features` -> `main` titled `feat(app): transcript status in sidebar (M6)`, to be merged as a merge commit by the owner. The body lists what changed, the T07 evidence and the CPU numbers. Confirm D6 handling with the owner if an earlier PR is unmerged.
- files: none
- done when: the PR is open with GATE, Protocol and ccgovd tests green locally, and its URL is in Log.
- verify: GATE; `cd <working copy>/Protocol && swift test`; `cd <working copy>/ccgovd && swift build && swift test`; `gh pr view feat/claude-code-features --json state,url,baseRefName`

### T09 Add prompt answering with a stale-prompt guard
- status: todo
- needs: T01, T05
- size: M
- scope: New `Prompt.swift` with `enum PromptAnswer`:
  - `keys(allow:) -> TerminalKey` per T01/D7
  - `eligible(_ status: TranscriptStatus) -> PendingTool?` per D10
  - `canSend(state:shownToolUseId:current:hasProcess:) -> Bool`: true only while the state is `.blocked`, the same tool_use id is still the single pending one, and the pane has a process

  `Pane.send(_ key: TerminalKey) -> Bool` wraps `terminal?.sendKey`. `WorkspaceModel.answer(sessionId:toolUseId:allow:)` checks the guard against a fresh status, sends the key, and sets `notice` when it refuses. The status reader and the key sender are injected closures (defaults no-op), like `paneProcess`.
- files: new `App/Sources/ClaudeTerm/Prompt.swift`; `App/Sources/ClaudeTerm/Workspace.swift:9-38` (Pane.send), `102-152` (init closures), new `answer` near `close` (`:364`); new `App/Tests/ClaudeTermTests/PromptTests.swift`; `App/Tests/ClaudeTermTests/WorkspaceTests.swift`
- done when: tests show:
  - allow sends `digit1` and deny sends `escape`
  - nothing is sent when the state is not `.blocked`, when the pending id changed, when two tools are pending, for an excluded tool, or for a pane with no process

  Each check fails if its guard clause is removed.
- verify: FOCUSED with `<TestClass>` = `PromptTests`; FOCUSED with `WorkspaceTests`; GATE

### T10 Add Allow / Deny buttons to waiting rows
- status: todo
- needs: T09, T06
- size: S
- scope: In `SessionRow`, when `isWaiting` and `PromptAnswer.eligible` returns a tool for a session with an open pane, replace `Waiting for you` with the pending tool line plus `Allow` and `Deny` buttons. The buttons call `model.answer` with the tool_use id captured when they were drawn. Other waiting rows keep the current text. Clicking a button does not select the row or focus the pane.
- files: `App/Sources/ClaudeTerm/Views.swift:329-385` (SessionRow body, isWaiting)
- done when: the app builds. A blocked row with one eligible pending tool shows both buttons; an AskUserQuestion row shows none.
- verify: GATE, then BUILD

### T11 Add Allow / Deny notification actions
- status: todo
- needs: T09
- size: M
- scope:
  - Register `UNNotificationCategory` `waiting-prompt` with actions `allow` / `deny` (no `.foreground`) in `AttentionNotifier.start()`.
  - In `handle`, for a session with a launched pane and an eligible pending tool, set `categoryIdentifier`, put the tool line in `body`, and add `toolUseId` to `userInfo`. The pending tool comes from a fresh tail-parse of that one transcript, not the 2 s cache, because the cache can lag the blocked state. All other notifications stay as they are.
  - `didReceive` branches on `actionIdentifier`: allow/deny call a new `onAnswer` closure without activating the app; the default action keeps `onOpen`.
  - `Bootstrap` wires `onAnswer` to `model.answer` and the pending lookup to the status parser.
  - The category and content decision is a pure function, tested next to `WaitingTracker`.
- files: `App/Sources/ClaudeTerm/Attention.swift:37-92`; `App/Sources/ClaudeTerm/ClaudeTermApp.swift:159-166`; `App/Tests/ClaudeTermTests/SidebarTests.swift` (where the `WaitingTracker` tests live)
- done when: tests show:
  - the category is set only when the pane is launched and the tool is eligible
  - the body carries the tool line
  - `userInfo` has the id

  The default click still opens the session.
- verify: FOCUSED with `<TestClass>` = `SidebarTests`; GATE

### T12 Live check M7: answer from notification and sidebar
- status: todo
- needs: T10, T11
- size: S
- scope: Run the BUILD app with two panes.
  - In the background pane, trigger a Bash prompt (`touch /tmp/ct-m7-allow`). Approve from the notification. The file exists, and the selected pane never changes.
  - Trigger `touch /tmp/ct-m7-deny`. Deny from the sidebar. The file does not exist.
  - Stale guard: answer a prompt in the terminal, then click the old button. Nothing is sent and a notice shows.
  - Confirm D10 by triggering an AskUserQuestion: no buttons appear.
- files: none
- done when: `build/live-m7.png` (row with buttons) is saved, and Log records the four results.
- verify: BUILD; `test -e /tmp/ct-m7-allow && ! test -e /tmp/ct-m7-deny && echo PASS`; `screencapture -x <working copy>/build/live-m7.png`

### T13 Land M7
- status: todo
- needs: T12
- size: S
- scope: Push, then open the PR `feat(app): answer permission prompts inline (M7)`, or comment on the open PR per D6. Merge commit by the owner.
- files: none
- done when: the PR is open or commented with the T12 evidence, the checks are green locally, and the URL is in Log.
- verify: GATE; `cd <working copy>/Protocol && swift test`; `cd <working copy>/ccgovd && swift build && swift test`; `gh pr view feat/claude-code-features --json state,url`

### T14 Add worktree launch flag and name rules
- status: todo
- needs: T03
- size: S
- scope:
  - `ClaudeCommand.newSession(id:cwd:executable:worktree: String? = nil)` appends `-w <name>`.
  - New `Worktree.swift` holds `enum Worktree`:
    - `isValidName`: allowlist `[A-Za-z0-9._-]`, no leading `-` or `.`, at most 64 chars, narrowed further by T03's findings. The name lands in libghostty's `bash -c` string (`ClaudeCommand.swift:19-23`), so it must be shell-inert.
    - `defaultName(project:date:)` = sanitized project name + `-` + `yyMMdd-HHmm`.
    - `path(repo:name:)` per T03.
    - `parentRepo(of cwd:) -> String?` for paths inside `<repo>/.claude/worktrees/<name>`.
  - An invalid name throws a new `LaunchError.invalidWorktreeName`.
- files: `App/Sources/ClaudeTerm/ClaudeCommand.swift:4-46`; new `App/Sources/ClaudeTerm/Worktree.swift`; `App/Tests/ClaudeTermTests/LaunchTests.swift`
- done when: tests show:
  - the argv has `-w name` after `--session-id`
  - spaces, `$`, `;`, a leading `-` and an over-long name are rejected
  - the default name is valid for a project with spaces in its name
  - `parentRepo` maps a worktree path back to its repo and returns nil for a plain path
- verify: FOCUSED with `<TestClass>` = `LaunchTests`; GATE

### T15 Open a pane in a new worktree
- status: todo
- needs: T14, T09
- size: M
- scope:
  - `Pane` gets `worktree: (repo: String, name: String)?`. Its `cwd` is the worktree path (D11). Launch uses the repo root as the spec cwd and passes `worktree:` for `.new`; `.resume` uses the worktree path.
  - `WorkspaceModel.newWorktreeSession(from cwd: String, name: String)`:
    - resolves the repo root with `git -C <cwd> rev-parse --show-toplevel` off the main thread, via the runner `GitStatusModel` uses (`GitStatus.swift:60-75`)
    - refuses non-repos, invalid names, and an existing worktree path, each with a `notice`
    - inserts the pane next to its parent project's panes
  - Persisted `PaneRecord.cwd` is the worktree path, so restore resumes there.
- files: `App/Sources/ClaudeTerm/Workspace.swift:9-38` (Pane), `243-253` (newSession), `304-307` (insert), `425-441` (launchIfNeeded); `App/Tests/ClaudeTermTests/WorkspaceTests.swift`
- done when: tests with injected `claudePath` and a fake repo-root resolver show:
  - the spec has `-w name` with cwd = repo root
  - the pane cwd and persisted record = worktree path
  - resume after restore uses `--resume` in the worktree path
  - a non-repo is refused with a notice
- verify: FOCUSED with `<TestClass>` = `WorkspaceTests`; GATE

### T16 Add Cmd-Shift-T new-worktree sheet
- status: todo
- needs: T15, T11
- size: S
- scope:
  - Menu item `New Session in Worktree...` with Cmd-Shift-T in `CommandGroup(replacing: .newItem)`, disabled with no selection.
  - A sheet (`WorktreeSheet` in `Worktree.swift`) with a name field prefilled by `Worktree.defaultName`, inline validation, and Create/Cancel.
  - Add `Shortcuts.newWorktree`.
  - If a focused pane swallows Cmd-Shift-T, add `super+shift+t` to `Pane.unboundKeys`.
- files: `App/Sources/ClaudeTerm/ClaudeTermApp.swift:34-42`; `App/Sources/ClaudeTerm/Worktree.swift`; `App/Sources/ClaudeTerm/Sidebar.swift:207-222` (Shortcuts); `App/Sources/ClaudeTerm/Workspace.swift:46-49` (only if needed)
- done when: the app builds. With a terminal pane focused, Cmd-Shift-T opens the sheet, and an invalid name disables Create.
- verify: GATE, then BUILD

### T17 Group worktree sessions under their parent project
- status: todo
- needs: T16, T10
- size: M
- scope:
  - `SidebarLayout.projects` groups by `Worktree.parentRepo(of: cwd) ?? cwd`.
  - `PaneOrder.insertionIndex` / `grouped` use the same key, so Cmd-numbers still read top to bottom.
  - `SessionRow` shows a branch badge (`arrow.triangle.branch` + name) for worktree rows. The name comes from T03's branch rule, without running git, if the branch is derived from `<name>`; otherwise from one `git rev-parse --abbrev-ref HEAD` per worktree pane at open.
  - `RowMenu` gets `Reveal Worktree` for worktree rows (D2: no delete action).
- files: `App/Sources/ClaudeTerm/Sidebar.swift:26-84`; `App/Sources/ClaudeTerm/Views.swift:329-420,447-479`; `App/Tests/ClaudeTermTests/SidebarTests.swift`
- done when: tests show:
  - a worktree session sits in its parent's group
  - an open worktree pane counts as opening the parent
  - pane order follows sidebar order with a worktree pane mixed in
  - existing grouping tests are unchanged and green
- verify: FOCUSED with `<TestClass>` = `SidebarTests`; GATE; BUILD

### T18 Live check M8: worktree session
- status: todo
- needs: T17
- size: S
- scope: With the BUILD app on this repo, press Cmd-Shift-T and accept the default name.
  - The session starts in the T03 path, and `git worktree list` shows it.
  - The row sits under `claude-code-terminal` with a branch badge.
  - Quit and relaunch the app (from Terminal.app): the pane resumes in the worktree.
  - Close the pane: the worktree is still listed (D2).
  - Remove the test worktree afterwards with `git worktree remove`.
- files: none
- done when: `build/live-m8.png` is saved, and Log has the `git worktree list` output before and after closing.
- verify: BUILD; `git worktree list` in the repo; `screencapture -x <working copy>/build/live-m8.png`

### T19 Land M8
- status: todo
- needs: T18
- size: S
- scope: Push, then open the PR `feat(app): new session in a worktree (M8)`, or comment on the open PR per D6.
- files: none
- done when: the PR is open or commented with the T18 evidence, the checks are green locally, and the URL is in Log.
- verify: GATE; `cd <working copy>/Protocol && swift test`; `cd <working copy>/ccgovd && swift build && swift test`; `gh pr view feat/claude-code-features --json state,url`

### T20 Add config scanners for skills, agents and hooks
- status: todo
- needs: none
- size: M
- scope: New `Config.swift` with `enum ConfigScanner` (pure, home and project paths injected):
  - skills: `~/.claude/skills/*/SKILL.md`, `<project>/.claude/skills/*/SKILL.md`, and plugin skills per D13 (confirm by listing `~/.claude/plugins`)
  - agents: `~/.claude/agents/*.md`, `<project>/.claude/agents/*.md`
  - names and descriptions come from YAML front matter, with a fallback to the file name
  - hooks: event -> matcher -> command, from `~/.claude/settings.json`, `<project>/.claude/settings.json` and `<project>/.claude/settings.local.json`
  - every item carries `scope` (user, project, local, plugin) and its file path

  Rules:
  - The settings decoder does not decode `env` or any key other than `hooks`.
  - A path guard refuses any file whose name starts with `.env`.
  - Unreadable files become one "unreadable" row instead of failing the scan.

  Unused until T22, so it lands safely in any earlier PR.
- files: new `App/Sources/ClaudeTerm/Config.swift`; new `App/Tests/ClaudeTermTests/ConfigTests.swift` (temp dirs)
- done when: tests show:
  - each scope is found and labelled
  - front matter is parsed, with the fallback for a missing name
  - garbled settings JSON gives an "unreadable" row
  - a secret placed in a fixture `env` value appears in no output string
  - the guard refuses `.env` and `.env.local`
- verify: FOCUSED with `<TestClass>` = `ConfigTests`; GATE

### T21 Add cached `claude mcp list` reader
- status: todo
- needs: T20
- size: M
- scope:
  - `McpListModel` in `Config.swift` runs `claude mcp list` (binary from `Bootstrap.claude`) with cwd = project, off the main thread, with a 30 s timeout. Results are cached per project path; a Refresh re-runs.
  - A tolerant line parser keeps only name, status (connected, failed, needs auth, unknown) and the `plugin:` prefix, and drops everything after the name/status split, so no args or URLs are shown.
  - Scope per D12.
  - The fixture comes from one real run with arguments replaced by placeholders.
- files: `App/Sources/ClaudeTerm/Config.swift`; `App/Tests/ClaudeTermTests/ConfigTests.swift`
- done when: tests show:
  - the fixture parses to the right names and statuses
  - an unknown line is skipped
  - no output string contains a fixture argument or URL
  - the timeout path yields an error state, not a hang
- verify: FOCUSED with `<TestClass>` = `ConfigTests`; GATE

### T22 Add the Config tab
- status: todo
- needs: T21, T17
- size: M
- scope:
  - Add `DetailTab.config = "Config"`. `TabSwitcher` picks it up automatically.
  - `ContentView` overlays `ConfigView` like Usage, scoped to `model.selectedSession?.cwd`. Its empty state reads "Select a session".
  - Go menu `Config` with Cmd-Ctrl-3, plus `Shortcuts.configTab` and the help text in the toolbar tooltip.
  - New `ConfigView.swift`: sections MCP servers, Skills, Agents, Hooks. Each row has its name, scope tag and one detail line. Clicking reveals the file in Finder per D14. MCP shows a spinner while loading and a Refresh button.
  - Cmd-Shift-U keeps toggling Sessions / Usage only.
- files: `App/Sources/ClaudeTerm/Views.swift:7-11,13-55`; `App/Sources/ClaudeTerm/ClaudeTermApp.swift:84-90`; `App/Sources/ClaudeTerm/Sidebar.swift:207-222`; new `App/Sources/ClaudeTerm/ConfigView.swift`
- done when: the app builds. Cmd-Ctrl-1/2/3 switch tabs, existing tab tests stay green, and selecting another session returns to Sessions as today (`Views.swift:41`).
- verify: GATE, then BUILD

### T23 Live check M9: Config tab
- status: todo
- needs: T22
- size: S
- scope: With the BUILD app, select a session in this repo and open Config.
  - The MCP names match `claude mcp list` run in the repo.
  - Skills, agents and hooks match the files on disk.
  - No env value or MCP argument is visible.
  - Confirm D12-D14.
- files: none
- done when:
  - `build/live-m9.png` is saved
  - Log has the shell `claude mcp list` names next to the tab's names
  - the grep below shows `.env` only in the guard
- verify: `claude mcp list` in the repo; `rg -n '\.env' App/Sources/ClaudeTerm/Config.swift App/Sources/ClaudeTerm/ConfigView.swift`; `screencapture -x <working copy>/build/live-m9.png`

### T24 Land M9
- status: todo
- needs: T23
- size: S
- scope: Push, then open the PR `feat(app): config browser tab (M9)`, or comment on the open PR per D6.
- files: none
- done when: the PR is open or commented with the T23 evidence, the checks are green locally, and the URL is in Log.
- verify: GATE; `cd <working copy>/Protocol && swift test`; `cd <working copy>/ccgovd && swift build && swift test`; `gh pr view feat/claude-code-features --json state,url`

### TZZ Cleanup and land
- status: todo
- needs: every other todo
- scope: run `/implement cleanup`
- done when: skill removed from the branch, TODO.md archived, landing PR into main open and approved by the owner

## Backlog
- Transcript search (not picked 2026-11-12)
- Session diff panel (not picked 2026-11-12)
- Prompt palette (not picked 2026-11-12)
- "New Session in Worktree" in the row context menu (only Cmd-Shift-T and the menu bar are in scope)
- Worktree cleanup from the app (excluded by D2; stays with `git-worktree-clean`)
- A worktree pane whose folder is gone (claude's own `/exit` removes a clean `-w` worktree, T03): restore would `--resume` in a missing cwd. Show it as gone instead of launching (found 2026-11-12)

## Log
- 2026-11-12 T01 done. Spike ran a Debug build with a scratch layout (`CCTERM_LAYOUT_PATH`), a temporary Go-menu item calling `Pane.terminal?.sendKey`, and a spike folder whose `.claude/settings.json` forced a Bash prompt (the owner's `defaultMode: auto` approved `touch` with no prompt). Claude Code 2.1.322. Spike code dropped; `git status` clean; GATE green (74 tests in 18 suites).
  - (a) Yes. A hidden pane (`isSurfaceVisible = false`) keeps its surface: `sendKey` returned true for `1`, Esc and `2`, and each key reached claude.
  - (b) `1` approves once (`touch /tmp/ct-spike` ran; tool_result "(Bash completed with no output)"). Esc denies (tool_result "The user doesn't want to proceed with this tool use..." then "[Request interrupted by user for tool use]"). `2` depends on the menu: with no `ask` rule it approved (file created; no `settings.local.json` written, so session-scoped). With an `ask` rule matching the command it rejected, because that menu has no "don't ask again" option and `2` is No. The app must never send `2`. D7 confirmed.
  - (c) Yes. The assistant line with the pending `tool_use` (`"name":"Bash","input":{"command":"touch /tmp/ct-spike"...}`) is the last message line in the jsonl while the prompt is on screen, with no matching `tool_result` yet.
  - (d) Yes. After relaunch, the saved-selected pane has `hasProcess=true`; the other restored pane has `hasProcess=false`, `terminal=nil`, and `sendKey` on it returned false. So it gets no buttons.
- 2026-11-12 T02 transcript findings (Claude Code 2.1.322; read the last 200 lines of 26 recent transcripts, including sessions whose context passed 200K tokens and a Sonnet session).
  - Each line is one JSON object with a top-level `type`: `user`, `assistant`, `attachment`, `system`, `api-request`, `api-request-blob`, `mode`, `ai-title`, `last-prompt`, `queue-operation`, `file-history-snapshot` and others. Only `user` and `assistant` lines carry `message`.
  - `tool_use`: an item in `message.content` of an `assistant` line, `{"type":"tool_use","id","name","input","caller"}`. One API message is split across several `assistant` lines (thinking, text and each tool_use on its own line, same `message.id`).
  - `tool_result`: an item in `message.content` of a `user` line, `{"type":"tool_result","tool_use_id","content"}`, plus `"is_error"` when set.
  - `message.usage`: `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `output_tokens` (also `cache_creation`, `iterations`, `service_tier`, `speed`). Context = input + cache read + cache creation.
  - `message.model`: e.g. `claude-opus-5-5`, `claude-sonnet-5-5`. `<synthetic>` appears on locally generated assistant lines (with zero usage); skip those for model and context. The top-level `requestedModel` field repeats the model without a window suffix.
  - Sidechain: every line has `isSidechain`. In the main file it is always `false`. Subagent lines live in a separate file, `<project>/<sessionId>/subagents/agent-<agentId>.jsonl`, with `isSidechain: true` and an `agentId` field. The main file's status needs no sidechain filter, but the parser should still skip `isSidechain: true` lines.
  - 1M window (D8): none -> tokens > 200K fallback. `message.model`, `requestedModel`, the `api-request` `params.model` and `params.betas` look the same in sessions above and below 200K (no `context-1m` beta, no `[1m]` suffix).
  - Fixture lines for T04 (hand-made and scrubbed; line 7 is deliberately garbled):
    ```
    {"type":"user","isSidechain":false,"uuid":"u1","timestamp":"2026-11-12T04:00:00.000Z","message":{"role":"user","content":"Fixture prompt"}}
    {"type":"assistant","isSidechain":false,"uuid":"a1","timestamp":"2026-11-12T04:00:02.000Z","message":{"id":"msg_1","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"echo fixture","description":"Fixture command"},"caller":{"type":"direct"}}],"usage":{"input_tokens":2,"cache_read_input_tokens":40000,"cache_creation_input_tokens":500,"output_tokens":30}}}
    {"type":"user","isSidechain":false,"uuid":"u2","timestamp":"2026-11-12T04:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"fixture output"}]}}
    {"type":"assistant","isSidechain":true,"agentId":"agentfixture","uuid":"s1","timestamp":"2026-11-12T04:00:04.000Z","message":{"id":"msg_s","model":"claude-sonnet-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_s","name":"Read","input":{"file_path":"fixture.txt"},"caller":{"type":"direct"}}],"usage":{"input_tokens":3,"cache_read_input_tokens":9000,"cache_creation_input_tokens":0,"output_tokens":12}}}
    {"type":"assistant","isSidechain":false,"uuid":"a2","timestamp":"2026-11-12T04:00:06.000Z","message":{"id":"msg_2","model":"claude-opus-5-5","role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_2","name":"Edit","input":{"file_path":"fixture.swift","old_string":"a","new_string":"b"},"caller":{"type":"direct"}}],"usage":{"input_tokens":1,"cache_read_input_tokens":210000,"cache_creation_input_tokens":1200,"output_tokens":80}}}
    {"type":"system","subtype":"turn_duration","isSidechain":false,"uuid":"y1","timestamp":"2026-11-12T04:00:07.000Z","durationMs":7000}
    {"type":"assistant","isSidechain":false,"message":{"model":
    {"type":"user","isSidechain":false,"uuid":"u3","timestamp":"2026-11-12T04:00:09.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","content":"denied","is_error":true}]}}
    ```
    Lines 1-6 end with `toolu_2` (Edit) pending on the main thread and context 211,201 (so the 1M fallback applies). The sidechain `toolu_s` never counts. Line 7 must be skipped. Line 8 resolves `toolu_2`.
  - CPU baseline (M6 before): BUILD (Release, this branch at 375e2dc), 8 restored panes all started (8 `claude --resume` children of ClaudeTerm), scratch layout via `CCTERM_LAYOUT_PATH`, idle 60 s, then the verify `top` command: avg 16.5% (12 samples 13.9-19.9). System load average during the run 6.3 (other sessions running), so T07 should measure under similar load or re-take this baseline in the same sitting.
- 2026-11-12 T03 done. Scratch repo `/tmp/ct-wt-spike` (`git init`, one commit); interactive `claude` driven in a detached tmux on Claude Code 2.1.322.
  - Trust first: `claude -w` in a folder that was never trusted exits 1 with "Error creating worktree: Workspace trust not yet accepted. Run `claude` once in this directory and accept the trust dialog, then retry with --worktree." T15/T16 must surface that message (or check trust) instead of showing a dead pane.
  - Path and branch: `claude --session-id <id> -w spike-a` creates `<repo>/.claude/worktrees/spike-a` on branch `worktree-spike-a`, from HEAD; `git worktree list` shows it `locked` while claude runs.
  - `--session-id` is honoured with `-w`: the transcript is `<id>.jsonl`. While the session ran it was under `~/.claude/projects/-private-tmp-ct-wt-spike--claude-worktrees-spike-a/` (project dir from the worktree path). After `/exit` it was under the launch folder's project dir instead (`-private-tmp-ct-wt-spike/` for a launch from the repo root, `-private-tmp-ct-wt-spike-sub/` for a launch from `sub`), and the worktree project dir was left empty. A later `--resume` from the worktree found it there and did not move it back. So T04/T05 must find a transcript by `~/.claude/projects/*/<id>.jsonl` on each poll, not cache a path derived from the pane cwd.
  - `claude agents --json` reports `"cwd": "/private/tmp/ct-wt-spike/.claude/worktrees/spike-a"` (note the `/private` realpath of `/tmp`) and `"name": "spike-a-fc"`.
  - `claude --resume <id>` run from the worktree folder resumes it (prior prompt and reply shown).
  - Names: `a.b`, `a_b` and `--worktree=-x` are accepted as-is. `a/b` is accepted and becomes folder `a+b`. Rejected with exit 1: `a b` ("Invalid worktree name "a b": each "/"-separated segment must be non-empty and contain only letters, digits, dots, underscores, and dashes"), `.` and `..` ("must not contain "." or ".." path segments"). `-w -x` fails as "error: unknown option '-x'", so the app must pass `--worktree=<name>` or reject a leading dash.
  - From a subfolder (`<repo>/sub`): the worktree still goes to `<repo>/.claude/worktrees/<name>`, and the session cwd is the worktree root, not `<worktree>/sub`.
  - Exit behaviour: `/exit` in a session with no changes prints "Cleaning up worktree (no pending changes)" and removes the worktree and its branch. With uncommitted changes it asks Keep / Remove (Keep is the default). SIGTERM, which is how Close Pane stops claude (`Takeover.stop`), leaves the worktree in place (still marked `locked`). So D2 holds for Close Pane, but a user's own `/exit` can delete a clean worktree (Backlog item added).
  - D11 confirmed, with the corrections above: the recorded cwd is the worktree root even from a subfolder, and the path may come back with `/private` prefixed.
- 2026-11-12 T04 done. `Transcript.swift` adds `TranscriptStatus.parse` (pending main-thread tool_uses, activity, context tokens, model), `contextLimit` (200K, or 1M above 200K tokens) and `ContextLevel` (amber >= 0.70, red >= 0.85). `TranscriptTests` has 16 tests built on the T02 fixture lines. Mutation checks: removing the sidechain skip failed 4 tests; removing tool_result matching failed 4 tests. Code review (sonnet) found 3 Medium issues plus a test gap; fixed: text blocks are checked one by one for a real prompt, the wrapper-tag regex also matches underscores, digits, uppercase and attributes, and the unspecified `[1m]` model rule was dropped (4 tests added; the old regex fails the new wrapper test). GATE green (90 tests in 19 suites). Notes for T05/T09: an `isMeta` line or a `<command-name>` wrapper does not clear pending; a user line with both a tool_result and a text block clears everything; an assistant line without `usage` keeps the previous context value.
