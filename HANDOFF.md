# HANDOFF

## Done
- M3, M4, M1, M2, integration, memory target (M5 not needed), final review gate. Proof and numbers in STATE.md.
- Gates green: Protocol 7, ccgovd 26, app 23 tests.

## In progress
- Nothing.

## Next
1. User live validation: `make install-daemon`, then the hooks snippet (see final report / `ccgovd/hooks/README.md`).
2. Follow-ups: paginate large sessions snapshots; start-time revalidation in `scripts/fleet.sh stop`; window frame size on relaunch (SwiftUI may override it).

## Open decisions
- Default install is read-only; governing needs `GOVERN=1`.

## Resume commands
```
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/Protocol && swift test
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/ccgovd && swift build && swift test
cd /Users/hotingyuen/Desktop/claude-projects/claude-code-terminal/App && xcodegen generate && xcodebuild -scheme ClaudeTerm -destination 'platform=macOS' build test
```
