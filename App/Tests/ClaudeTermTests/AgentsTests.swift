import CCProtocol
import Foundation
import Testing
@testable import ClaudeTerm

struct AgentsTests {
    static let json = """
    [
      {"pid": 100, "cwd": "/work/a", "kind": "interactive", "startedAt": 1762500000000,
       "sessionId": "11111111-1111-4111-8111-111111111111", "name": "alpha", "status": "busy", "extra": {"x": 1}},
      {"id": "bg-1", "cwd": "/work/b", "kind": "background", "startedAt": 1762500000001,
       "sessionId": "22222222-2222-4222-8222-222222222222", "name": "beta", "state": "blocked"},
      {"pid": 300, "cwd": "/work/a"}
    ]
    """

    @Test func decodesInteractiveAndBackgroundShapes() throws {
        let sessions = try AgentsPollingSource.build(agentsJSON: Data(Self.json.utf8), psOutput: "")
        #expect(sessions.count == 3)

        let interactive = sessions[0]
        #expect(interactive.kind == .interactive)
        #expect(interactive.pid == 100)
        #expect(interactive.state == .running)
        #expect(interactive.name == "alpha")

        let background = sessions[1]
        #expect(background.kind == .background)
        #expect(background.pid == nil)
        #expect(background.state == .blocked)
        #expect(background.sessionId == "22222222-2222-4222-8222-222222222222")

        // Missing fields are tolerated.
        #expect(sessions[2].state == .unknown)
    }

    @Test func nonArrayPayloadThrowsSoThePreviousListIsKept() {
        #expect(throws: (any Error).self) {
            try AgentsDecoder.decode(Data("{\"error\":1}".utf8))
        }
    }

    @Test func groupsByCwdNotByFolderName() {
        func s(_ id: String, _ cwd: String, _ name: String) -> SessionInfo {
            SessionInfo(sessionId: id, cwd: cwd, name: name, kind: .interactive, state: .idle)
        }
        let groups = SessionGrouping.group([
            s("1", "/work/app", "zeta"), s("2", "/other/app", "x"), s("3", "/work/app", "alpha"), s("4", "/work/lib", "y"),
        ])
        #expect(groups.map(\.path) == ["/other/app", "/work/app", "/work/lib"])
        #expect(groups[1].sessions.map(\.sessionId) == ["3", "1"])
    }

    @Test func treeRSSSumsRootAndDescendantsOnly() {
        let ps = """
          100     1   1000
          101   100    500
          102   101    250
          200     1   9999
          103   100    not-a-number
        """
        let table = ProcessTable(psOutput: ps)
        #expect(table.treeRSSBytes(root: 100) == (1000 + 500 + 250) * 1024)
        #expect(table.descendants(of: 100).sorted() == [101, 102])
        #expect(table.treeRSSBytes(root: 999) == 0)

        let sessions = try? AgentsPollingSource.build(
            agentsJSON: Data(#"[{"pid":100,"cwd":"/w","sessionId":"s","status":"idle"}]"#.utf8), psOutput: ps)
        #expect(sessions?.first?.rssBytes == 1750 * 1024)
        #expect(sessions?.first?.childCount == 2)
    }
}
