# HANDOFF

## Done
- Repo + private GitHub repo `0xnicholasy/claude-code-terminal`, SPEC.md, `Protocol/` (CCProtocol, tests green), `scripts/fleet.sh` (throwaway fleet: start/pids/rss/stop, verified on 1 session: 846,448 KB tree RSS, stop leaves nothing).

## In progress
- App lane (M3, M4) and daemon lane (M1, M2): subagents in git worktrees under `.claude/worktrees/`.

## Next
1. Merge lane branches into `main`, run gates (below), commit + push per milestone.
2. Integration: `DaemonSocketSource` in the app, fallback to `AgentsPollingSource`.
3. Live checks (screenshots under `docs/screens/`), memory target with `scripts/fleet.sh start 8`.
4. Final review gate, STATE.md / HANDOFF.md / tasks/todo.md.

## Open decisions
- None blocking. Codex plan review skipped (usage limit); retry on final diff.

## Resume commands
```
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal && git worktree list && git log --oneline --all | head -20
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/Protocol && swift test
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/ccgovd && swift build && swift test
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/App && xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test
```
