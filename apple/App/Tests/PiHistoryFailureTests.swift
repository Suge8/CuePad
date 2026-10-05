#if os(macOS)
import CuePi
import Foundation
import OSLog
import SQLite3
import Testing
@testable import CuePad

/// Pi 历史索引读写 Store 失败：报告问题，并停止该文件的写回（库异常时反复重写只会放大问题）。
@MainActor
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
            for file in files { continuation.yield(.updated(try! PiHistory.index(file: file, from: nil))) }
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
        #expect(await services.loadPiCheckpoint(for: broken) == nil)
        guard case .piHistoryUnavailable(let message)? = services.startupIssues.first else {
            Issue.record("读检查点失败没有进入 startupIssues：\(services.startupIssues)")
            return
        }
        #expect(message.contains(broken.path))

        await services.consumePiHistory(events(for: [broken, healthy]))

        #expect(services.startupIssues.count == 2, "broken 不再写回，healthy 仍尝试写入（并同样失败）")
        guard case .piHistoryUnavailable(let second)? = services.startupIssues.last else { return }
        #expect(second.contains(healthy.path))
    }

    @Test func 写入失败同样报告并停止该文件写回() async throws {
        let file = try sessionFile("s")
        try breakPiSessionTable()

        await services.consumePiHistory(events(for: [file, file]))

        #expect(services.startupIssues.count == 1)
    }

    @Test func 检查点解码失败是合法的重读_不报问题_写回照常() async throws {
        let file = try sessionFile("stale")
        let garbage = Data("not a checkpoint".utf8)
        try await services.store.upsertPiSession(
            StoredPiSession(id: "stale", path: file.path, cwd: "/work/x", lastActivityAt: .now), checkpoint: garbage, host: TestApp.hostID)

        #expect(await services.loadPiCheckpoint(for: file) == nil)
        await services.consumePiHistory(events(for: [file]))

        #expect(services.startupIssues.isEmpty)
        #expect(try await services.store.piCheckpoint(of: "stale") != garbage)
        // 测试输出里的那行"检查点无法解码，从头重读"就是这里预期的诊断日志
        let logged = try OSLogStore(scope: .currentProcessIdentifier).getEntries()
            .compactMap { $0 as? OSLogEntryLog }
            .contains { $0.subsystem == "com.sugeh.cuepad" && $0.category == "pi-history" && $0.composedMessage.contains(file.path) }
        #expect(logged, "检查点解码失败要留下诊断日志")
    }
}
#endif
