import Foundation
import Testing
@testable import CCProtocol

@Test func requestRoundTrip() throws {
    let req = Request(id: "1", cmd: .hibernate, sessionId: "13d7b27d-1d5f-433f-8d50-9b66d8af2db1")
    let line = try WireLine.encode(req)
    #expect(line.last == 0x0A)
    let back = try WireLine.decode(Request.self, from: line.dropLast())
    #expect(back == req)
}

@Test func responseWithSessionsRoundTrip() throws {
    let s = SessionInfo(sessionId: "13d7b27d-1d5f-433f-8d50-9b66d8af2db1", cwd: "/tmp/p", kind: .interactive,
                        state: .idle, pid: 42, rssBytes: 1_000, childCount: 2)
    let resp = Response(id: "x", ok: true, sessions: [s], totals: Totals(rssBytes: 1_000, cpuPercent: 0, count: 1))
    let back = try WireLine.decode(Response.self, from: try WireLine.encode(resp).dropLast())
    #expect(back == resp)
    #expect(back.sessions?.first?.projectName == "p")
}

@Test func hookEventUsesClaudeFieldNames() throws {
    let json = #"{"hook_event_name":"SessionStart","session_id":"13d7b27d-1d5f-433f-8d50-9b66d8af2db1","cwd":"/x","transcript_path":"/t.jsonl"}"#
    let ev = try JSONDecoder().decode(HookEvent.self, from: Data(json.utf8))
    #expect(ev.hookEventName == "SessionStart")
    #expect(ev.transcriptPath == "/t.jsonl")
}

@Test func stateMapping() {
    #expect(SessionState(agentsRaw: "busy") == .running)
    #expect(SessionState(agentsRaw: "idle") == .idle)
    #expect(SessionState(agentsRaw: "blocked") == .blocked)
    #expect(SessionState(agentsRaw: nil) == .unknown)
}

@Test func resumeCommandRejectsNonUUID() {
    #expect(ResumeCommand.make(sessionId: "abc; rm -rf ~", cwd: "/tmp") == nil)
    #expect(ResumeCommand.make(sessionId: "--dangerously-skip-permissions", cwd: "/tmp") == nil)
}

@Test func resumeCommandQuotesCwd() throws {
    let cmd = try #require(ResumeCommand.make(sessionId: "13d7b27d-1d5f-433f-8d50-9b66d8af2db1", cwd: "/tmp/it's here"))
    #expect(cmd.shellLine == "cd '/tmp/it'\\''s here' && 'claude' --resume 13d7b27d-1d5f-433f-8d50-9b66d8af2db1")
    #expect(cmd.argv == ["claude", "--resume", "13d7b27d-1d5f-433f-8d50-9b66d8af2db1"])
}

@Test func socketPathOverrideAndLength() {
    #expect(SocketPath.resolve(environment: ["CCGOVD_SOCKET": "/tmp/a.sock"]) == "/tmp/a.sock")
    let def = SocketPath.resolve(environment: ["HOME": "/Users/hotingyuen"])
    #expect(def.utf8.count <= SocketPath.maxPathBytes)
}
