Build the native Claude Code terminal described in `tasks/todo.md`, milestones M3, M4, M1, M2, then M5 only if needed, in this one session. Run unattended until "Done when" holds or a hard-stop cap trips.

## Goal
A native macOS app (working name ClaudeTerm) plus a background daemon (`ccgovd`):
- One window lists every Claude Code session on this Mac, grouped by project, with state (running / idle / hibernated) and live RSS.
- Quitting the app or rebooting loses no session: each comes back via `claude --resume <id>` in its cwd when its pane is focused.
- The daemon cuts memory by demoting unfocused sessions and hibernating idle ones (kill, then resume on demand).

## Givens (decided; do not re-ask)
- Run target: local. Project root: `/Users/hotingyuen/Desktop/claude-projects/claude-code-terminal`.
- Read first, in order: `tasks/todo.md` (plan, architecture, milestones, pass criteria), `docs/research.md` (evidence, sources, constraints). The plan is the spec; this prompt overrides it only where stated.
- Toolchain verified 2026-11-07: Xcode 27.1, Swift 6.4, macOS 27.0.1, `xcodegen` at /opt/homebrew/bin, `sqlite3`, `gh` logged in as `0xnicholasy`. Claude Code 2.1.319.
- Terminal library: libghostty via the `Lakr233/libghostty-spm` Swift package (MIT; products `GhosttyKit`, `GhosttyTerminal`). Pin one exact release in Package.swift / project.yml; the ABI still changes before 1.0.
- Session index: `claude agents --json` (verified: returns interactive sessions with `pid`, plus background ones, with `cwd`, `sessionId`, `name`, `state`; no TTY needed). Never parse JSONL message bodies; the format is internal.
- Build order: M3 then M4 (app lane), M1 then M2 (daemon lane), then integration (sidebar reads the `ccgovd` socket instead of polling `claude agents --json`), then M5 only if the memory target below is unmet.
- Git: the folder is not a repo. `git init`, `.gitignore` for Xcode/SwiftPM (`build/`, `.build/`, `DerivedData/`, `*.xcuserstate`). Create a PRIVATE GitHub repo `0xnicholasy/claude-code-terminal` with `gh repo create --private --source . --push`. Commit to `main` and push after each milestone that passes its gate. Conventional commits. Before every commit: `git branch --show-current`, fresh `git status`, `git diff --cached --stat`; stage your own files by path.
- Live-process safety (hard rule): tests that demote, SIGTERM, hibernate, or resume sessions may only touch `claude` processes the test itself started, in scratch dirs under `$TMPDIR/ccterm-test/`. The user's real sessions may only be READ (pid, RSS, CPU). Every signal-sending code path takes an explicit pid allowlist in test mode; add a unit test proving a pid outside the allowlist is never signalled.
- Throwaway sessions for tests: create a transcript cheaply with `claude -p "reply with OK" --model haiku --session-id <uuid>` in a scratch dir, then start an interactive `claude --resume <uuid>` in a PTY to get a live process to govern. Do not send further prompts. Clean up every test process on exit (trap).
- launchd: write `ccgovd/launchd/com.hotingyuen.ccgovd.plist` and a `make install-daemon` target. Do NOT load it and do not run `launchctl`.
- Existing job to coexist with: `~/Library/LaunchAgents/com.hotingyuen.claude-cpu-watcher.plist` runs `~/Library/Scripts/claude-cpu-watcher.sh` every 120 s and runs a cleanup script on high total claude CPU. Do not modify or unload it. Note the interaction in `docs/research.md` if it matters.
- Hibernate default: 30 min idle, configurable; pinned sessions and sessions with an active child command are never hibernated.
- Out of scope: live PTY survival across app quit (v2), Windows/Linux, any change under `~/.claude/` except an opt-in hooks snippet written to `ccgovd/hooks/` with install instructions (do not edit `~/.claude/settings.json`).

## Autonomy
- Do not stop to ask the user; they have walked away. Do not stop or wrap up because you feel low on context: that instinct is usually wrong. Continue until "Done when" holds or a hard-stop cap trips, whichever comes first.
- Emergent forks not covered above: choose the lowest-risk, most reversible option, log it with one line of reasoning under "Decisions" in `STATE.md`, continue. Stop for the human only if a fork is irreversible and not covered by Givens.
- Approval gates (stop and ask): adding any dependency other than libghostty-spm and GRDB/SQLite.swift (prefer the system `sqlite3` C API, which needs none); anything touching auth, payments, or the user's real sessions beyond reading; deleting files you did not create.

## State and handoff
- Keep `STATE.md` at the repo root: current milestone, done, in progress, next, decisions, lessons. Update at every milestone boundary.
- Before context gets genuinely tight, and at each milestone boundary, write `HANDOFF.md` (done / in progress / next / open decisions / exact commands to resume) so a fresh session can continue from files, not from a summary.
- Tick boxes in `tasks/todo.md` as items land. After any correction or fix of your own mistake, add the rule to `tasks/lessons.md`.

## Approach and orchestration
1. Spec pass (main session, short): turn `tasks/todo.md` into `SPEC.md` with the module layout (`App/` via xcodegen `project.yml`, `ccgovd/` SwiftPM package with `CCGovCore` library + `ccgovd` executable, shared `Protocol/` types for the socket JSON lines), the socket protocol (request/response/event shapes), and per-milestone done-contracts copied from the todo pass criteria. Keep it high level; no line-by-line code.
2. Two lanes in parallel, because app and daemon touch disjoint directories: spawn both subagents in ONE message.
   - App lane (M3, M4): `general-purpose` on sonnet, `isolation: worktree`, budget 80 tool calls. Scope: `App/`, `Protocol/`.
   - Daemon lane (M1, M2): `general-purpose` on sonnet, `isolation: worktree`, budget 80 tool calls. Scope: `ccgovd/`, `Protocol/` (read-only for this lane; the spec fixes it).
   Each brief names: the SPEC.md sections it owns, its done-contracts, the live-process safety rule verbatim, its build/test commands, "return partial work plus what is left on hitting the cap". The main session merges both worktrees into `main`, resolves conflicts, and runs the gates.
3. Integration (main session): switch the sidebar from polling `claude agents --json` to the `ccgovd` socket; fall back to polling when the socket is absent.
4. Use `codex` once on SPEC.md before fanning out (plan review) and once on the final full diff. Cost is high; do not use it per milestone.
5. Use the `/run` skill to launch and drive the built app for live checks (screenshots of the sidebar and a pane running `claude`). Use `triage-bug` for any bug that survives one fix attempt.
6. Subagent caps from the user's rules: at most 3 concurrent, 6 total for this task. Narrowest agent type that fits; `quick-search` (haiku) for lookups such as libghostty-spm API questions in its README.

## Review gate (each milestone, before its commit)
- `swift build` and `swift test` for `ccgovd/` green (60 s minimum timeout).
- `xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test` green (60 s minimum timeout; retry once longer on timeout).
- No `any`/force casts added without a justifying comment; no emoji in code.
- The milestone's pass criterion from `tasks/todo.md` demonstrated with output (logs, `ps` numbers, screenshot path), not asserted.
- Tests: roughly one focused test per stated behavior, sized like a small package. Tests must fail if the logic changes (e.g. hibernate threshold, allowlist enforcement, layout round-trip).

Final gate, after the last milestone:
- Run `/code-review` (fresh subagent, not this conversation) on the full diff; fix every correctness finding.
- Run `security-reviewer` once: the daemon accepts socket input, spawns `claude` with arguments, and sends signals. Check socket permissions (0600, user-owned path), argument injection into spawned commands, and pid-reuse races before signalling (verify pid start time).
- Checker is not maker: the verifier subagent gets only SPEC.md done-contracts and the running app/daemon, not your reasoning, and returns pass/fail per criterion.

## On failure
Root cause, then fix, then re-run the exact failing command or input, then lock it as a test or a `tasks/lessons.md` line. If two fix attempts on the same problem break more than they fix, revert to the last green commit and rethink before a third.

## Done when (all objectively checked)
1. App builds and launches; one pane runs `claude` in a chosen project dir with working keyboard, paste, and resize (screenshot saved under `docs/screens/`).
2. Sidebar shows every session from `claude agents --json` (and later the socket), grouped by project, with RSS. Count matches `claude agents --json | jq length` at test time.
3. Persistence: quit app, relaunch: layout restored; focusing a restored pane runs `claude --resume <id>` in its cwd and the transcript history is visible. Reboot survival is argued from on-disk state (layout file + transcripts), not tested.
4. Daemon: `ccgovd status` RSS totals within 5% of `ps` for the same pids; demote/restore verified with `taskpolicy` state on a throwaway session; hibernate then resume of a throwaway session keeps its conversation (check via transcript sessionId and a `claude -p --resume <id> "what did I ask first?"` haiku call).
5. Memory target, measured on a throwaway fleet of 8 idle sessions: after one governor cycle, total RSS of the fleet (claude + children) drops at least 40% versus before. App RSS with 8 panes under 150 MB, excluding claude processes. If this misses, do M5, then re-measure.
6. All gates green, `/code-review` and `security-reviewer` findings fixed, everything committed and pushed to the private repo, `STATE.md` and `HANDOFF.md` current, `tasks/todo.md` ticked.

## Hard stops
- Wall clock 8 hours, or 600 main-session tool calls, whichever comes first.
- Per milestone: at most 3 failed gate runs, then write HANDOFF.md with the blocker and stop.
- On any hard stop: commit the last green state, push, write HANDOFF.md, and end with a one-line status per milestone.

## Final report
For each milestone: works / partly / not started, with the proof (command plus output line, screenshot path). Then live-validation steps still to run by the user, each as a self-contained command (`cd <abs path> && ...`) with the output that means pass, starting with `make install-daemon` and enabling the hooks snippet. List low-confidence points separately.
