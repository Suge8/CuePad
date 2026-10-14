#if os(macOS)
import CuePi
import CueStore
import Foundation
import OSLog
import SQLite3
import Testing
@testable import CuePad

/// Pi 历史索引读写 Store 失败：报告问题，并停止该文件的写回（库异常时反复重写只会放大问题）。
struct PiHistoryFailureTests {
    let app = TestApp()
    var services: AppServices { app.services }

    private func sessionFile(_ id: String) throws -> URL {
        let directory = app.directory.appending(path: "sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(id).jsonl")
        let header = #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/work/x"}"#
        try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func events(for files: [URL]) -> AsyncStream<PiHistoryEvent> {
        AsyncStream { continuation in
            for file in files { continuation.yield(.updated(try! PiHistory.index(file: file, agent: .pi, from: nil, files: services.store.files))) }
            continuation.finish()
        }
    }

    /// 让资料库里的 Pi 会话表消失：之后 Store 对它的读写都真实地失败。
    private func breakPiSessionTable() throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(services.location.databaseURL.path, &handle) == SQLITE_OK,
              sqlite3_exec(handle, "DROP TABLE piSessions", nil, nil, nil) == SQLITE_OK
        else { throw BreakFailed() }
    }

    struct BreakFailed: Error {}

    @Test func 读检查点失败_报告问题并停止该文件写回_其他文件照常尝试() async throws {
        let broken = try sessionFile("broken")
        let healthy = try sessionFile("healthy")
        try breakPiSessionTable()

        // 读失败：当作从头重读，但必须可见
        #expect(await services.loadHistoryStart(for: broken) == nil)
        guard case .piHistoryUnavailable(let message)? = services.startupIssues.first else {
            Issue.record("读检查点失败没有进入 startupIssues：\(services.startupIssues)")
            return
        }
        #expect(message.contains(broken.path))

        await services.consumePiHistory(events(for: [broken, healthy]), agent: .pi)

        #expect(services.startupIssues.count == 2, "broken 不再写回，healthy 仍尝试写入（并同样失败）")
        guard case .piHistoryUnavailable(let second)? = services.startupIssues.last else { return }
        #expect(second.contains(healthy.path))
    }

    /// 首次回填按批写：一批里一个文件写不进去，同批其余的照常写进去，只挡住写不进去的那个，问题只报它。
    @Test func 一批里一个文件写失败_其余照常写入_只挡住失败的那个() async throws {
        let bad = try sessionFile("bad")
        let good = try sessionFile("good")
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open(services.location.databaseURL.path, &handle) == SQLITE_OK, sqlite3_exec(handle, """
            CREATE TRIGGER rejectBad BEFORE INSERT ON piSessions WHEN NEW.id = 'bad' BEGIN SELECT RAISE(ABORT, 'boom'); END;
            """, nil, nil, nil) == SQLITE_OK else { throw BreakFailed() }

        await services.consumePiHistory(events(for: [bad, good]), agent: .pi)

        #expect(try await services.store.piSessions().map(\.id) == ["good"])
        #expect(services.startupIssues.count == 1)
        guard case .piHistoryUnavailable(let message)? = services.startupIssues.first else { return }
        #expect(message.contains(bad.path) && !message.contains(good.path))
    }

    @Test func 写入失败同样报告并停止该文件写回() async throws {
        let file = try sessionFile("s")
        try breakPiSessionTable()

        await services.consumePiHistory(events(for: [file, file]), agent: .pi)

        #expect(services.startupIssues.count == 1)
    }

    @Test func 检查点解码失败是合法的重读_不报问题_写回照常() async throws {
        let file = try sessionFile("stale")
        let garbage = Data("not a checkpoint".utf8)
        try await services.store.upsertPiSession(
            IndexedSession(id: "stale", path: file.path, cwd: "/work/x", lastActivityAt: .now), checkpoint: garbage, host: TestApp.hostID)

        #expect(await services.loadHistoryStart(for: file)?.checkpoint == nil)
        await services.consumePiHistory(AsyncStream { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, agent: .pi, from: nil, files: services.store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }, agent: .pi)

        #expect(services.startupIssues.isEmpty)
        #expect(try await services.store.piCheckpoint(of: "stale") != garbage)
    }
}
#endif
