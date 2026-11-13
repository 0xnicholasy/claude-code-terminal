# Claude Code features, round 2

ultraplan: claude-code-features | branch: feat/claude-code-features | base: main | tag: pre-claude-code-features-main | created: 2026-11-12
Status: ACTIVE
Progress: 18/27 done

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
- D6 If an earlier milestone's PR is still unmerged when the next landing todo runs, that todo comments on the open PR (listing the new milestone) instead of opening a second one. | applied by T13 (2026-11-13): PR #10 still open; GitHub allows only one open PR per head and base, so a second PR was not possible anyway
- D7 Claude Code 2.1.322 permission prompt: `1` (`TerminalKey.digit1`) approves once and Esc (`TerminalKey.escape`) denies. | confirmed by T01 (2026-11-12)
- D8 The app passes no model flag at launch (`ClaudeCommand.swift:27-33`), so the 1M window must be detected from the transcript. If no field marks it, fall back to 1M once context tokens exceed 200K. | confirmed by T02 (2026-11-12): no field marks it. Amended by T06a (2026-11-12, owner choice after T07): models in `TranscriptStatus.millionTokenModels` (`claude-opus-5-5`) count as 1M from the start, because `/context` reports Opus 5.5 sessions as `/1m` while the 200K fallback showed them about 4x too full.
- D9 CPU budget: with 8 idle open panes, M6 may add at most 1.0 percentage point to the app's average CPU over 60 s. | confirmed by T07 (2026-11-12): +0.9 points over 3 pairs, little margin
- D10 Allow/Deny is offered only when the transcript has exactly one pending main-thread `tool_use` and its tool is not `AskUserQuestion`, `ExitPlanMode`, `Task` or `Agent`. Those have other menus, or the prompt belongs to a subagent. | confirmed live by T12 (AskUserQuestion row shows "Waiting for you", no buttons), 2026-11-13
- D11 `claude -w <name>` combines with `--session-id <uuid>`, creates `<repo>/.claude/worktrees/<name>`, and the session's cwd is the worktree path. The pane records that path as its cwd, so restore and `--resume` run there. | confirmed by T03 (2026-11-12), with the trust and auto-removal notes in its Log entry
- D12 MCP rows show server name, scope and health status only. Scope comes from server names in `<project>/.mcp.json` and `~/.claude.json` (only the `mcpServers` key names are decoded) and from the `plugin:` prefix; anything else shows "unknown". | assumed, confirm by T21
- D13 Plugin skills are found under `~/.claude/plugins/**/skills/*/SKILL.md`. | assumed, confirm by T20
- D14 Clicking a Config row reveals its file in Finder (`NSWorkspace.activateFileViewerSelecting`). MCP rows have no click action. | assumed, confirm by T23
- D15 Inline Allow (sidebar row, T10; notification, T11) is offered only when the shown text is the whole action: a single-line Bash command of at most 60 characters, or a file tool (`Edit`, `Write`, `Read`, `NotebookEdit`) whose path is inside the session's project folder, shown project-relative. Any other tool gets no inline Allow; the row shows "Waiting for you" and the notification stays plain. The row's help text carries the full command or path. The notification body is hidden on a locked screen. Raised by the automated security review of T10 and T11. | owner, 2026-11-12 (picked "Restrict"); built by T12a

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
- status: done (#5, 2026-11-12)
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
- status: done (#6, 2026-11-12)
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
- status: done (#7, 2026-11-12)
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

### T06a Model table for the 1M context window
- status: done (#8, 2026-11-12)
- needs: T06
- size: S
- scope: Added by the owner after T07 found the ring at 42.5% of 200K while `/context` showed `85.1k/1m (9%)`. `TranscriptStatus.contextLimit` returns 1M for a model id starting with an entry of `millionTokenModels` (`claude-opus-5-5`), keeps the over-200K fallback, else 200K.
- files: `App/Sources/ClaudeTerm/Transcript.swift` (contextLimit), `App/Tests/ClaudeTermTests/TranscriptTests.swift`
- done when: an Opus 5.5 session under 200K tokens reports a 1M limit; other models keep 200K until usage passes it; GATE is green.
- verify: GATE

### T07 Live check M6: activity line, context ring, CPU
- status: done (#9, 2026-11-12)
- needs: T06, T06a
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
- status: done (#11, 2026-11-12)
- needs: T07
- size: S
- scope: Push the branch and open the PR `feat/claude-code-features` -> `main` titled `feat(app): transcript status in sidebar (M6)`, to be merged as a merge commit by the owner. The body lists what changed, the T07 evidence and the CPU numbers. Confirm D6 handling with the owner if an earlier PR is unmerged.
- files: none
- done when: the PR is open with GATE, Protocol and ccgovd tests green locally, and its URL is in Log.
- verify: GATE; `cd <working copy>/Protocol && swift test`; `cd <working copy>/ccgovd && swift build && swift test`; `gh pr view feat/claude-code-features --json state,url,baseRefName`

### T09 Add prompt answering with a stale-prompt guard
- status: done (#12, 2026-11-12)
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
- status: done (#13, 2026-11-12)
- needs: T09, T06
- size: S
- scope: In `SessionRow`, when `isWaiting` and `PromptAnswer.eligible` returns a tool for a session with an open pane, replace `Waiting for you` with the pending tool line plus `Allow` and `Deny` buttons. The buttons call `model.answer` with the tool_use id captured when they were drawn. Other waiting rows keep the current text. Clicking a button does not select the row or focus the pane.
- files: `App/Sources/ClaudeTerm/Views.swift:329-385` (SessionRow body, isWaiting)
- done when: the app builds. A blocked row with one eligible pending tool shows both buttons; an AskUserQuestion row shows none.
- verify: GATE, then BUILD

### T11 Add Allow / Deny notification actions
- status: done (#14, 2026-11-12)
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

### T12a Show inline Allow only for a fully visible action (D15)
- status: done (#15, 2026-11-12)
- needs: T10, T11
- size: M
- scope: Added by the owner after the security review of T10/T11 (D15).
  - `TranscriptStatus.PendingTool` gets the tool's full input text (`detail`: the whole Bash command, or the file path; nil for other tools), filled by the parser.
  - `PromptAnswer` gets `label(_:cwd:) -> String?`: `Bash: <command>` for a single-line command of at most 60 characters; `<Tool> <project-relative path>` for a file tool whose path resolves inside `cwd` (symlinks resolved on both sides, so `/tmp` vs `/private/tmp` match); nil otherwise. `eligible(_:cwd:)` also requires a non-nil label, so `canSend`, the row and the notification all apply the same rule.
  - The row and the notification show the label instead of `summary`; the row's help text adds the full `detail`.
  - The `waiting-prompt` category sets `hiddenPreviewsBodyPlaceholder`, so the command is not shown on a locked screen.
- files: `App/Sources/ClaudeTerm/Transcript.swift` (PendingTool, summary), `App/Sources/ClaudeTerm/Prompt.swift`, `App/Sources/ClaudeTerm/Workspace.swift` (`answer`), `App/Sources/ClaudeTerm/Views.swift` (SessionRow, PromptButtons), `App/Sources/ClaudeTerm/Attention.swift`; tests in `PromptTests`, `TranscriptTests`, `WorkspaceTests`, `SidebarTests`
- done when: tests show:
  - a 60-character single-line Bash command is eligible; 61 characters or a two-line command is not
  - a file path inside the project is eligible and labelled project-relative; a path outside it, or a `..` path that escapes it, is not
  - a `/tmp/...` project matches a `/private/tmp/...` path
  - a tool other than Bash or the file tools is not eligible
  - `answer` refuses an ineligible long command, and the notification content stays plain for it

  Each check fails if its rule is removed. GATE is green.
- verify: FOCUSED with `PromptTests`, `TranscriptTests`, `WorkspaceTests`, `SidebarTests`; GATE; BUILD

### T12 Live check M7: answer from notification and sidebar
- status: done
- needs: T10, T11, T12a
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
- status: done (#17, 2026-11-13)
- needs: T12
- size: S
- scope: Push, then open the PR `feat(app): answer permission prompts inline (M7)`, or comment on the open PR per D6. Merge commit by the owner.
- files: none
- done when: the PR is open or commented with the T12 evidence, the checks are green locally, and the URL is in Log.
- verify: GATE; `cd <working copy>/Protocol && swift test`; `cd <working copy>/ccgovd && swift build && swift test`; `gh pr view feat/claude-code-features --json state,url`

### T14 Add worktree launch flag and name rules
- status: done (#18, 2026-11-13)
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
- status: done (#19, 2026-11-13)
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
- status: done (#PRNUM, 2026-11-13)
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
  - T16 checks (deferred here by the owner, 2026-11-13): with a terminal pane focused, Cmd-Shift-T opens the sheet (not Ghostty's undo); typing `a b` or `-x` disables Create; the field takes typing without a click.
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
- Prompt guard gap (T09 review, Medium): session state refreshes every 5 s (`SessionSource` and ccgovd `intervalSec`), and an approved tool that is still running has no `tool_result` yet, so for up to about 5 s after the user answers in the terminal the guard still passes. A late Deny then sends Esc, which interrupts the running tool; a late Allow types a stray `1`. Needs a signal that the prompt is still on screen (fresher state at click time, or a transcript or hook marker); T12 should measure whether Claude Code writes anything at approval time (found 2026-11-12)
- Same-minute worktree names (T14 review, Low): `Worktree.defaultName` has minute resolution, so two sessions for one project started in the same minute get the same name; what `claude -w` does with an existing worktree is untested. T16's sheet should check `Worktree.path` exists and suggest a suffix (found 2026-11-13)
- Worktree pane saved before claude creates the folder (T15 review, Medium): `newWorktreeSession` persists the pane at once, so if claude never creates the worktree (trust dialog refused, no claude binary, quit first) restore resumes a session that never existed in a missing folder. Same fix as the gone-worktree item above: on restore, show a pane whose cwd is missing as gone instead of launching (found 2026-11-13)
- Worktree placement uses git's real path (T15 review, Low): `git rev-parse --show-toplevel` returns e.g. `/private/tmp/x` while a pane's cwd may be `/tmp/x`, so the new pane lands at the end instead of next to its project; T17 grouping should compare resolved paths. A git timeout is also reported as "Not a git repository" (found 2026-11-13)
- Worktree sheet closes before the session is checked (T16 review, Low): a refused name ("already exists", e.g. two default names in the same minute) shows only as a notice after the sheet is gone, and the typed name is lost (found 2026-11-13)

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
- 2026-11-12 T05 done. `TranscriptStatusModel` (in `Transcript.swift`) polls every 2 s over `model.panes.filter(\.hasProcess)`, reads a 256 KB tail only when the mtime changes, and reads and parses off the main actor. It publishes only when a status changes, so an idle window is not re-rendered every tick. Paths are cached per id. A vanished file re-resolves on the next tick (T03: transcripts move after exit). A transcript not found yet (a new session before its first message) is looked up again only every 5th tick. A failed read is retried. Closed ids are dropped. Created in `Bootstrap.makeTranscripts`, started in the app's `.task` after the `isUnderTest` guard, and passed to `ContentView`. Review (sonnet): 2 Medium issues and a weak test, all fixed. Tests: 6 new (22 in TranscriptTests); mutations of the process filter, mtime skip, miss backoff and publish each fail a test. GATE green (96 tests in 19 suites). Not validated live yet; the live check is T07.
- 2026-11-12 T06 done. `SidebarView` takes `statuses` from `TranscriptStatusModel` and passes each `SessionRow` its `TranscriptStatus?`. While running, the row shows the last pending tool's summary, or "Working" between tool calls, so the row height does not jump on every tool start and finish (a review finding). An always-visible `ContextRing` (11 pt) is coloured by `ContextLevel` with the new `Palette.contextAmber` / `contextRed`. The help text adds `TranscriptStatus.contextHelp`, e.g. "Context: 132K of 200K (66%)", using integer percent so 29% does not show as 28%. Rendered with `ImageRenderer` in a scratch test (not committed): light and dark PNGs show the activity lines, the waiting line, and normal/amber/red rings. A live window screenshot was not possible: the app opened in the background and its window was not listed for capture. Review (sonnet): 2 Medium; row-height jitter fixed, whole-sidebar re-render on a status change accepted (bounded to one render per real change). GATE green (97 tests in 19 suites); BUILD ok.
- 2026-11-12 T06a done. Owner picked the model table after T07's ring check failed (ring 42.5% of 200K, `/context` 85.1k/1m). `contextLimit` returns 1M for `claude-opus-5-5*`, keeps the over-200K fallback, else 200K; D8 amended. 2 tests changed/added; removing the table line fails the new test (3 issues). GATE green (98 tests in 19 suites).
- 2026-11-12 T07 done (after T06a). Earlier attempts this day are kept below. BUILD (Release, this branch at 21e746f), scratch layout via `CCTERM_LAYOUT_PATH`, Claude Code 2.1.322.
  - Activity line: pass. Asked claude to run `sleep 20 && echo done`; frames every ~1.4 s show the row change from `Working` to `Bash: sleep 20 && echo…` within 2.5 s of the tool_use and back to `Working` within 2.8 s of the tool_result (limit 4 s each). Screenshot `build/live-m6.png`.
  - Ring vs `/context`: fail. Context tokens agree (parser 84,973; `/context` 85.1k), but `/context` reports `85.1k/1m tokens (9%)` while the ring uses the 200K limit (42.5%). The session is Opus 5.5 with `"model": "opus"` in settings and `claude-opus-5-5` in the transcript, so no local signal marks the 1M window; the D8 fallback (1M only above 200K tokens) is wrong for every 1M session below 200K.
  - CPU: not measured validly. Pre-M6 (`ccf-baseline`, f82e826) with 8 panes started via Cmd-1..8: 16.1% (load 4.7-8.8) and 18.8% (load 8.4-14.4). The M6 build, launched the same way with the same layout, started only 3 and then 2 of the 8 `claude` children, so its 30.2% and 24.6% readings (load 15-18) are not comparable. Not yet known whether that is an M6 regression (pane start or Cmd-number mapping) or the high system load.
  - CPU follow-up: at load ~2, a step-by-step Cmd-1..8 run (4 s gaps) started 8/8 panes on both the M6 and pre-M6 builds, so pane start is not an M6 regression. The scripted 60 s CPU run is still unreliable while the screen is in use (third attempt: M6 2/8 panes at 18.6%, pre-M6 0/8), so the before/after numbers within D9 are still open. Measure with the owner away from the keyboard, or start the 8 panes by hand.
  - Ring recheck after T06a (rebuilt at 186b88f): same session resumed; `/context` reports `85.1k/1m tokens (9%)`, the parser has 84,973 tokens of a 1M limit (8%), and the ring arc is about 8% full. Within 3 points: pass.
  - CPU, owner away from the keyboard (8/8 panes started on both builds, idle 60 s, then the T02 `top` command): M6 (186b88f) 18.2% (load 6.5-10.8), pre-M6 (f82e826) 13.5% (load 6.4-18.7). Difference +4.7 points, over the D9 budget of 1.0. Earlier pre-M6 runs in the same day read 16.1% and 18.8%, so run-to-run noise under this load is about 5 points; one pair cannot confirm or rule out a D9 breach.
  - CPU, 3 alternating pairs (owner asked for them; load 3.7-6.6, lower than before): pre-M6 15.6 / 15.2 / 15.8%, M6 16.5 / 16.6 / 16.3%. Means 15.5% vs 16.5%, +0.9 points, inside the D9 budget of 1.0 but with little margin. Pair 1's pre-M6 run started only 5 of 8 panes; without it the difference is still +0.95. The earlier single pair (+4.7) ran under load up to 18.7 and is treated as noise.
- 2026-11-12 T08 done. Landing PR #10 `feat(app): transcript status in sidebar (M6)`, `feat/claude-code-features` -> `main`, open for the owner to merge as a merge commit: https://github.com/0xnicholasy/claude-code-terminal/pull/10. No earlier landing PR existed, so D6 did not apply. Checks run locally at 431c134: GATE 98 tests in 19 suites passed; Protocol `swift test` 7 passed; ccgovd `swift build && swift test` 26 tests in 8 suites passed. The body carries the T07 evidence (activity line 2.5 s / 2.8 s, ring 8% vs `/context` 9%, CPU +0.9 points over 3 pairs).
- 2026-11-12 T09 done. New `Prompt.swift` (`PromptAnswer.keys`, `eligible` per D10, `canSend`), `Pane.send` (key path only, never `paste`), and `WorkspaceModel.answer(sessionId:toolUseId:allow:)`, which re-reads a fresh status through the injected `promptStatus` closure, checks the guard against the sidebar's `rows` state, sends through the injected `sendKey` closure, and sets `notice` on a refused or failed send. Tests: 5 in PromptTests (8 cases) and 8 new in WorkspaceTests. Mutations: removing each guard (`.blocked`, `hasProcess`, same id, one pending, excluded tools, allow/deny key, both notices, the fresh read) fails at least one test. GATE green (111 tests in 20 suites). Note for T10/T11: `promptStatus` defaults to nil, so `answer` refuses every prompt until T11 wires a fresh tail-parse in Bootstrap; a pane with a process but no `TerminalViewState` yet gets the "Could not send" notice. Review (sonnet): 1 Medium, recorded as a Backlog item rather than fixed (the guard cannot tell a prompt on screen from an approved tool still running for up to the 5 s state poll; no transcript signal is known yet). Lows fixed: the two notices are constants and the tests compare exact text. Not validated live; the live check is T12.
- 2026-11-12 T10 done. `SessionRow` shows `PromptButtons` (the pending tool's summary plus Allow and Deny, bordered mini buttons) instead of "Waiting for you" when the session is blocked, has an open pane, and `PromptAnswer.eligible` returns a tool. The buttons call `model.answer` with the tool_use id captured when they were drawn. Rendered with `NSHostingView` in a scratch test (not committed): a blocked Bash row shows `Bash: touch /tmp/ct-...` with Allow and Deny; a blocked AskUserQuestion row keeps "Waiting for you". Review (sonnet): 2 Medium, both fixed: the button line swallows taps in its gaps (`contentShape` + empty `onTapGesture`), so a near miss does not select the row, and the buttons are `fixedSize` with layout priority, so at a 220 pt sidebar the summary truncates (`Bash:...`) while Allow and Deny stay whole (re-rendered). Low fixed: buttons show only when the pane has a running process. GATE green (111 tests in 20 suites); BUILD ok. The buttons sit inside the row's own `Button`; that a click on them does not also select the row is checked live in T12. Until T11 wires `promptStatus`, every click is refused with the stale-prompt notice.
- 2026-11-12 T11 done. `AttentionNotifier.start()` registers category `waiting-prompt` with `allow` and `deny` (destructive), no `.foreground`. `handle` asks the pure `PromptNotification.content(launched:status:)`: for a session whose pane has a process and whose fresh tail-parse (`PromptNotification.freshStatus`, 256 KB, not the 2 s cache) has one eligible pending tool, it sets the category, shows the tool summary as the body and puts `toolUseId` in `userInfo`; every other notification is unchanged. `didReceive` sends allow/deny to `onAnswer` without activating the app; the default click still activates and opens the session. `Bootstrap.makeModel` wires `onAnswer` to `WorkspaceModel.answer` and the model's `promptStatus` to the same fresh read, so the T10 sidebar buttons now work too. Test `notificationButtonsNeedALaunchedPaneAndOneAnswerableTool` (5 cases); mutations of the launched check, `eligible`, the body and the id each fail it. Review (sonnet): 1 Medium fixed: the fresh read (a scan of `~/.claude/projects` plus a 256 KB parse) ran on the main actor in `handle`; it now runs in `Task.detached` and the notification is posted after it. Low fixed: Allow needs `.authenticationRequired`, so it cannot approve from a locked screen. Lows left: an answer from a banner gives no feedback outside the app (only `notice`); a notification posted before the tool_use line reaches the transcript stays plain; `WorkspaceModel.answer` still reads on the main actor (one click). GATE green (112 tests in 20 suites); BUILD ok. Not validated live; T12 checks the real notification buttons.
- 2026-11-12 T12a done (D15, owner picked "Restrict"). `PendingTool.detail` holds the whole Bash command, or the file path picked by tool (`file_path` for Edit/Write/Read, `notebook_path` for NotebookEdit). `PromptAnswer.label(_:cwd:)` gives the text shown on the row and the notification, or nil: Bash only when the trimmed command is printable ASCII (0x20-0x7E), at most 60 scalars, and runs neither outside the sandbox nor in the background; file tools only for an absolute path with no `..`, strictly inside an absolute project root that is not `/` or the home folder, with symlinks resolved on both sides (`lstat`-style existence, so a dangling link is refused), shown project-relative and printable ASCII. `eligible`, `canSend`, the row and the notification all require the label. The row shows the label on its own wrapping line with Allow and Deny below (never truncated) and puts the full detail in the help text; the notification category hides the body on a locked screen (`hiddenPreviewsBodyPlaceholder`). Review (sonnet): 5 Medium (hidden characters, path characters, NotebookEdit field, truncated label, `/` or home root) plus 3 Lows (dangling symlink, `..`, sandbox/background flags), all fixed in one round with a test each; mutations of each fix fail a test, except the scalar count, which the ASCII rule already covers. Render at 220 pt: a 54-character command wraps whole with buttons; a 77-character command shows "Waiting for you". GATE green (126 tests in 20 suites); BUILD ok. Not validated live: on a locked screen the body is hidden only when the user's Show Previews setting hides previews.
- 2026-11-13 T12 done (live, Release build, scratch project `/tmp/ct-m7` with `ask: ["Bash(touch:*)"]`, two panes; driven by computer use, notification click by the owner). (1) Sidebar row for a pending `touch /tmp/ct-m7-allow && ls -l ...` showed the full command with Allow and Deny and `Pending:` in the help text; sidebar Allow ran it (file exists) and the selected pane stayed pane 1. (2) Sidebar Deny on `touch /tmp/ct-m7-deny` sent Esc; the file does not exist and the session went idle. (3) Notification Allow: with ClaudeTerm notifications switched on in System Settings (they were off on the first try, so no banner showed), the owner clicked Allow on the banner for `touch /tmp/ct-m7-notif2`; the file was created and the selected pane stayed pane 1. (4) Stale guard: Esc in the terminal on `touch /tmp/ct-m7-stale`, then the row's old Allow within about 1 s: notice "That prompt is no longer waiting; nothing was sent." and no file. (5) D10: an AskUserQuestion prompt showed "Waiting for you" with no buttons. Spec verify `test -e /tmp/ct-m7-allow && ! test -e /tmp/ct-m7-deny && echo PASS` printed PASS. Evidence deviates from the spec: `build/live-m7.png` could not be captured (the ClaudeTerm window sat on another Space, and full-screen captures showed other apps, so they were deleted); the row's accessibility text is saved in `build/live-m7-ax.txt` instead. Not measured: whether Claude Code writes anything to the transcript at approval time (Backlog prompt-guard gap stays open); the stale check passed because Deny writes its `tool_result` at once.
- 2026-11-13 T13 done. Landing PR #10 (`feat/claude-code-features` -> `main`) was still open, so per D6 M7 was added by comment instead of a second PR: https://github.com/0xnicholasy/claude-code-terminal/pull/10#issuecomment-6841729049. The comment lists #12-#16 and the five T12 live results. Checks run locally at be66044: GATE 126 tests in 20 suites passed; Protocol `swift test` 7 passed; ccgovd `swift build && swift test` 26 tests in 8 suites passed. The PR title still names M6 only; the owner may retitle it on merge.
- 2026-11-13 T14 done. `ClaudeCommand.newSession(id:cwd:executable:worktree:)` appends `-w <name>` after `--session-id` and throws the new `LaunchError.invalidWorktreeName` for a bad name. New `Worktree.swift` (`enum Worktree`): `isValidName` allows `[A-Za-z0-9._-]`, at most 64 characters, no leading `-` (T03: `-w -x` parses as an option) or `.`, and, because the name becomes branch `worktree-<name>`, no `..`, trailing `.` or trailing `.lock`; `defaultName(project:date:timeZone:)` maps other characters to `-`, collapses runs of `-` and `.`, trims the ends, caps the base so the result stays within 64, falls back to `session`, and appends `-yyMMdd-HHmm`; `path(repo:name:)` is `<repo>/.claude/worktrees/<name>`; `parentRepo(of:)` maps a worktree path or a folder inside it back to the repo, and accepts any folder name but `.`/`..` because claude makes folders like `a+b`. LaunchTests has 4 new tests; FOCUSED 9 tests passed; removing the leading-dash check fails a test. Review (sonnet): 2 Medium fixed (git-invalid names like `a..b` passed; `parentRepo` returned nil for `a+b` folders), each with a test; its High (leading `-` accepted) came from reading the file during that mutation run and does not hold for the committed code; Lows: `path` does not validate the name (callers validate first) and same-minute names collide (Backlog). GATE green (130 tests in 20 suites).
- 2026-11-13 T15 done. `Pane` has `worktree: (repo, name)?`; its `cwd` is `<repo>/.claude/worktrees/<name>` (D11). `launchIfNeeded` starts a `.new` worktree pane with `ClaudeCommand.newSession(cwd: repo, worktree: name)`; after `markLaunched` the origin is `.resume`, and restore (which does not persist `worktree`) resumes in the worktree path. `WorkspaceModel.newWorktreeSession(from:name:)` validates the name, resolves the top level through the injected `repoRoot` (default `gitTopLevel`: `git -C <cwd> rev-parse --show-toplevel` via `ProcessRunner`, off the main actor, with `GitStatus.safeConfig`), maps a top level that is itself a worktree back to its repo, refuses a non-repo, a bad name, an existing folder or a pane already using that path (each with a `notice`), and inserts the pane after the last pane of the same repo or its worktrees. Tests: 5 new in WorkspaceTests (launch from repo root with `-w`, pane and saved cwd = worktree, restore `--resume` in the worktree; started from a worktree; placement after two worktree panes; non-repo, bad name and existing folder refused; a name still starting refused). Mutation: launching from `pane.cwd` instead of the repo fails 2 tests. Review (sonnet): its High (launch cwd = worktree path) was read from the file during that mutation run and does not hold; 1 Medium fixed (duplicate name while the first pane is starting, with a test), 1 Medium and 2 Lows to Backlog. FOCUSED WorkspaceTests 22 passed before the fixes; GATE green (135 tests in 20 suites). Not validated live; the live check is T18.
- 2026-11-13 T16 done. Go menu `New Session in Worktree...` (Cmd-Shift-T, in `CommandGroup(replacing: .newItem)`), disabled with no selection or while the sheet is open. It resolves the selected session's git top level first (`WorkspaceModel.gitTopLevel`, off the main actor; a non-repo gets a notice) and opens `WorktreeSheet` (in `Worktree.swift`): the name field is prefilled with `Worktree.defaultName` of the repo name (not the pane's subfolder; a worktree session maps back to its repo), the rule text turns red and Create is disabled for an invalid name, Return and Create both go through `isValidName`, and Create calls `newWorktreeSession(from:name:)`. `.id(req.id)` resets the name when the request is for another folder. `Shortcuts.newWorktree` added. Ghostty's default keybinds include `super+shift+t=undo` (`ghostty +list-keybinds --default`, Ghostty 1.4.0), so `super+shift+t` is added to `Pane.unboundKeys`. Review (sonnet): 1 Medium fixed (sheet named the pane's subfolder, not the repo); 2 Lows fixed (stale name after a selection change, item enabled while the sheet is open); Lows left: refused names surface after the sheet closes (Backlog), item enabled when only the About window is key, field focus unverified. GATE green (135 tests in 20 suites); BUILD ok. Not validated live: the owner's ClaudeTerm (from this build folder) was running, and the owner chose to move the sheet checks into T18's scope.
