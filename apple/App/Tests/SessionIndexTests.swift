#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话索引：一个会话文件只记成一个会话，会话 id 是文件头里的。Codex 的会话文件先建出来、文件头（`session_meta`）随后才写，
/// 这时读到它不能按文件名记一个会话——"全部"里会多出一行没名字的会话，读到文件头后又按真 id 记一条。
struct SessionIndexTests {
    private let realID = "01a1396a-0000-7000-8000-000000000001"

    /// Codex 的会话文件（`<CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<时间>-<会话 id>.jsonl`），建好目录；路径是真实路径
    /// （索引按 FSEvents 报的真实路径记，/var 是 /private/var）。
    private func codexFile(_ app: TestApp, _ id: String) throws -> URL {
        let day = app.directory.appending(path: "codex/sessions/2026/10/14", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let real = try #require(realpath(day.path, nil))
        defer { free(real) }
        return URL(filePath: String(cString: real), directoryHint: .isDirectory).appending(path: "rollout-2026-10-14T15-57-42-\(id).jsonl")
    }

    private func meta(_ id: String) -> Data {
        let line: [String: Any] = ["timestamp": "2026-10-14T07:57:42.000Z", "type": "session_meta", "payload": ["id": id, "cwd": "/work/demo"]]
        return try! JSONSerialization.data(withJSONObject: line) + Data("\n".utf8)
    }

    /// 启动时会话文件还是空的（文件头还没写）：回填不把它记成会话；文件头写上之后只有真 id 的那一个会话。
    @Test func 文件头还没写的Codex会话文件不按文件名记成会话() async throws {
        let app = TestApp()
        let pending = try codexFile(app, realID)
        FileManager.default.createFile(atPath: pending.path, contents: nil)
        // 回填一次写一批：另一个完整的会话被记下，就是回填读过这个空文件了
        let other = try codexFile(app, "01a1396a-0000-7000-8000-000000000002")
        try meta("01a1396a-0000-7000-8000-000000000002").write(to: other)
        try await app.connect(.codex)
        app.services.start()
        let store = app.services.store
        try await eventually("回填读过这两个文件") { try await store.piSession("01a1396a-0000-7000-8000-000000000002") != nil }

        let handle = try FileHandle(forWritingTo: pending)
        try handle.seekToEnd()
        try handle.write(contentsOf: meta(realID))
        try handle.close()
        try await eventually("文件头写上后记下了会话") { try await store.piSession(realID) != nil }

        #expect(try await store.piSessions().filter { $0.path == pending.path }.map(\.id) == [realID])
        #expect(try await !store.allPiSessionStates().contains { $0.sessionID == pending.deletingPathExtension().lastPathComponent })
        app.services.cancelBackgroundWork()
    }

    /// 已经按文件名记下的孤儿（旧版本留下的）：启动回填后收敛成一个，它的会话记录也删掉。
    @Test func 按文件名记下的孤儿会话启动时清掉() async throws {
        let app = TestApp()
        let file = try codexFile(app, realID)
        try meta(realID).write(to: file)
        let stem = file.deletingPathExtension().lastPathComponent
        let store = app.services.store
        try await store.upsertPiSessions([stem, realID].map { id in
            PiSessionUpsert(
                session: IndexedSession(id: id, path: file.path, cwd: "/work/demo", lastActivityAt: .now, agent: .codex), checkpoint: nil, transcript: nil)
        }, host: TestApp.hostID)
        #expect(try await store.allPiSessionStates().contains { $0.sessionID == stem })

        try await app.connect(.codex)
        app.services.start()
        try await eventually("孤儿清掉了") { try await !store.piSessions().contains { $0.id == stem } }
        #expect(try await store.piSessions().filter { $0.path == file.path }.map(\.id) == [realID])
        #expect(try await !store.allPiSessionStates().contains { $0.sessionID == stem })
        #expect(try await store.allPiSessionStates().contains { $0.sessionID == realID })
        app.services.cancelBackgroundWork()
    }

    /// 旧版本按文件名记下的孤儿，会话文件到启动时还是空的：启动对账就清掉它（空文件还不算会话）；文件头写上后只有真 id 的那一个。
    @Test func 文件还空着的孤儿会话启动时清掉() async throws {
        let app = TestApp()
        let file = try codexFile(app, realID)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let stem = file.deletingPathExtension().lastPathComponent
        let store = app.services.store
        try await store.upsertPiSessions([PiSessionUpsert(
            session: IndexedSession(id: stem, path: file.path, cwd: "", lastActivityAt: .now, agent: .codex), checkpoint: nil, transcript: nil)
        ], host: TestApp.hostID)

        try await app.connect(.codex)
        app.services.start()
        try await eventually("孤儿清掉了") {
            let sessions = try await store.piSessions(), states = try await store.allPiSessionStates()
            return !sessions.contains { $0.id == stem } && !states.contains { $0.sessionID == stem }
        }

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: meta(realID))
        try handle.close()
        try await eventually("文件头写上后记下了会话") { try await store.piSession(realID) != nil }
        #expect(try await store.piSessions().filter { $0.path == file.path }.map(\.id) == [realID])
        app.services.cancelBackgroundWork()
    }
}
#endif
