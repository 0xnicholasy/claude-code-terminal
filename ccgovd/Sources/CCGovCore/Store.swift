import Foundation
import SQLite3
import CCProtocol

public struct SessionRow: Equatable {
    public var sessionId: String
    public var cwd: String
    public var name: String?
    public var kind: String
    public var state: String
    public var pid: Int32?
    public var pidStartTime: UInt64?
    public var pinned: Bool
    public var demoted: Bool
    public var hibernated: Bool
    public var hibernatedAt: Int64?
    public var lastActivity: Int64?
    public var updatedAt: Int64

    public init(sessionId: String, cwd: String, name: String? = nil, kind: String, state: String,
                pid: Int32? = nil, pidStartTime: UInt64? = nil, pinned: Bool = false, demoted: Bool = false,
                hibernated: Bool = false, hibernatedAt: Int64? = nil, lastActivity: Int64? = nil, updatedAt: Int64 = 0) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.state = state
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.pinned = pinned
        self.demoted = demoted
        self.hibernated = hibernated
        self.hibernatedAt = hibernatedAt
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public var description: String
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite persistence for the session index. Every statement uses bound parameters.
public final class SessionStore {
    private var db: OpaquePointer?

    /// `path` may be `:memory:`.
    public init(path: String) throws {
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            throw StoreError(description: "sqlite open \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
        CREATE TABLE IF NOT EXISTS sessions (
          sessionId TEXT PRIMARY KEY,
          cwd TEXT NOT NULL,
          name TEXT,
          kind TEXT NOT NULL,
          state TEXT NOT NULL,
          pid INTEGER,
          pidStartTime INTEGER,
          pinned INTEGER NOT NULL DEFAULT 0,
          demoted INTEGER NOT NULL DEFAULT 0,
          hibernated INTEGER NOT NULL DEFAULT 0,
          hibernatedAt INTEGER,
          lastActivity INTEGER,
          updatedAt INTEGER NOT NULL
        )
        """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError(description: "sqlite exec: \(msg)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw StoreError(description: "sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        return s
    }

    private func bindText(_ s: OpaquePointer, _ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(s, i, v, -1, sqliteTransient) } else { sqlite3_bind_null(s, i) }
    }

    private func bindInt(_ s: OpaquePointer, _ i: Int32, _ v: Int64?) {
        if let v { sqlite3_bind_int64(s, i, v) } else { sqlite3_bind_null(s, i) }
    }

    private func step(_ s: OpaquePointer) throws {
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError(description: "sqlite step: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    public func upsert(_ r: SessionRow) throws {
        let s = try prepare("""
        INSERT INTO sessions (sessionId,cwd,name,kind,state,pid,pidStartTime,pinned,demoted,hibernated,hibernatedAt,lastActivity,updatedAt)
        VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
        ON CONFLICT(sessionId) DO UPDATE SET
          cwd=excluded.cwd, name=excluded.name, kind=excluded.kind, state=excluded.state, pid=excluded.pid,
          pidStartTime=excluded.pidStartTime, pinned=excluded.pinned, demoted=excluded.demoted,
          hibernated=excluded.hibernated, hibernatedAt=excluded.hibernatedAt,
          lastActivity=excluded.lastActivity, updatedAt=excluded.updatedAt
        """)
        defer { sqlite3_finalize(s) }
        bindText(s, 1, r.sessionId)
        bindText(s, 2, r.cwd)
        bindText(s, 3, r.name)
        bindText(s, 4, r.kind)
        bindText(s, 5, r.state)
        bindInt(s, 6, r.pid.map(Int64.init))
        bindInt(s, 7, r.pidStartTime.map { Int64(bitPattern: $0) })
        bindInt(s, 8, r.pinned ? 1 : 0)
        bindInt(s, 9, r.demoted ? 1 : 0)
        bindInt(s, 10, r.hibernated ? 1 : 0)
        bindInt(s, 11, r.hibernatedAt)
        bindInt(s, 12, r.lastActivity)
        bindInt(s, 13, r.updatedAt)
        try step(s)
    }

    private func readRows(_ s: OpaquePointer) -> [SessionRow] {
        var rows: [SessionRow] = []
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func int(_ i: Int32) -> Int64? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i) }
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(SessionRow(
                sessionId: text(0) ?? "", cwd: text(1) ?? "", name: text(2), kind: text(3) ?? "",
                state: text(4) ?? "", pid: int(5).map { Int32(truncatingIfNeeded: $0) },
                pidStartTime: int(6).map { UInt64(bitPattern: $0) },
                pinned: (int(7) ?? 0) != 0, demoted: (int(8) ?? 0) != 0, hibernated: (int(9) ?? 0) != 0,
                hibernatedAt: int(10), lastActivity: int(11), updatedAt: int(12) ?? 0))
        }
        return rows
    }

    private let columns = "sessionId,cwd,name,kind,state,pid,pidStartTime,pinned,demoted,hibernated,hibernatedAt,lastActivity,updatedAt"

    public func row(_ sessionId: String) throws -> SessionRow? {
        let s = try prepare("SELECT \(columns) FROM sessions WHERE sessionId = ?1")
        defer { sqlite3_finalize(s) }
        bindText(s, 1, sessionId)
        return readRows(s).first
    }

    public func all() throws -> [SessionRow] {
        let s = try prepare("SELECT \(columns) FROM sessions ORDER BY sessionId")
        defer { sqlite3_finalize(s) }
        return readRows(s)
    }

    public func delete(_ sessionId: String) throws {
        let s = try prepare("DELETE FROM sessions WHERE sessionId = ?1")
        defer { sqlite3_finalize(s) }
        bindText(s, 1, sessionId)
        try step(s)
    }

    private func updateFlag(_ column: String, _ sessionId: String, _ value: Int64?) throws {
        // `column` is chosen from a fixed set by the callers below, never from input.
        let s = try prepare("UPDATE sessions SET \(column) = ?1 WHERE sessionId = ?2")
        defer { sqlite3_finalize(s) }
        bindInt(s, 1, value)
        bindText(s, 2, sessionId)
        try step(s)
    }

    public func setPinned(_ id: String, _ v: Bool) throws { try updateFlag("pinned", id, v ? 1 : 0) }
    public func setDemoted(_ id: String, _ v: Bool) throws { try updateFlag("demoted", id, v ? 1 : 0) }
    public func setLastActivity(_ id: String, _ ms: Int64) throws { try updateFlag("lastActivity", id, ms) }

    public func markHibernated(_ id: String, atMs: Int64) throws {
        let s = try prepare("UPDATE sessions SET hibernated=1, hibernatedAt=?1, demoted=0, pid=NULL, pidStartTime=NULL, kind='hibernated', state='hibernated' WHERE sessionId=?2")
        defer { sqlite3_finalize(s) }
        bindInt(s, 1, atMs)
        bindText(s, 2, id)
        try step(s)
    }
}
