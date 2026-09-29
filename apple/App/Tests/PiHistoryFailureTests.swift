#if os(macOS)
import CuePi
import Foundation
import Testing
@testable import CuePad

/// 可注入读失败的索引存储：记录写入，按会话 id 决定读检查点是否失败或返回垃圾。
final class FlakyStorage: PiIndexStorage, @unchecked Sendable {
    struct ReadFailed: Error {}

    var sessions: [StoredPiSession] = []
    var failingReads: Set<String> = []
    var garbage: Set<String> = []
    private(set) var upserts: [String] = []

    func piSessions() async throws -> [StoredPiSession] { sessions }

    func piCheckpoint(of session: String) async throws -> Data? {
        if failingReads.contains(session) { throw ReadFailed() }
        return garbage.contains(session) ? Data("not a checkpoint".utf8) : nil
    }

    func upsertPiSession(_ session: StoredPiSession, checkpoint: Data?) async throws { upserts.append(session.id) }
}

@MainActor
struct PiHistoryFailureTests {
    private func sessionFile(_ id: String, in rig: Rig) throws -> URL {
        let directory = rig.directory.appending(path: "sessions")
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

    @Test func Store读检查点失败_报告问题并停止该文件写回_其他文件不受影响() async throws {
        let storage = FlakyStorage()
        let rig = Rig(historyStorage: storage)
        let broken = try sessionFile("broken", in: rig)
        let healthy = try sessionFile("healthy", in: rig)
        storage.sessions = [
            StoredPiSession(id: "broken", path: broken.path, cwd: "/work/x", lastActivityAt: .now),
            StoredPiSession(id: "healthy", path: healthy.path, cwd: "/work/x", lastActivityAt: .now),
        ]
        storage.failingReads = ["broken"]

        // 读失败：当作从头重读，但必须可见
        #expect(await rig.services.loadPiCheckpoint(for: broken) == nil)
        guard case .piHistoryUnavailable(let message)? = rig.services.startupIssues.first else {
            Issue.record("读检查点失败没有进入 startupIssues：\(rig.services.startupIssues)")
            return
        }
        #expect(message.contains(broken.path))

        await rig.services.consumePiHistory(events(for: [broken, healthy]))

        #expect(storage.upserts == ["healthy"])
        #expect(rig.services.startupIssues.count == 1)
    }

    @Test func 检查点解码失败是合法的重读_不报问题_写回照常() async throws {
        let storage = FlakyStorage()
        let rig = Rig(historyStorage: storage)
        let file = try sessionFile("stale", in: rig)
        storage.sessions = [StoredPiSession(id: "stale", path: file.path, cwd: "/work/x", lastActivityAt: .now)]
        storage.garbage = ["stale"]

        #expect(await rig.services.loadPiCheckpoint(for: file) == nil)
        await rig.services.consumePiHistory(events(for: [file]))

        #expect(rig.services.startupIssues.isEmpty)
        #expect(storage.upserts == ["stale"])
    }

    @Test func 写入失败同样报告并停止该文件写回() async throws {
        let storage = FailingWrites()
        let rig = Rig(historyStorage: storage)
        let file = try sessionFile("s", in: rig)

        await rig.services.consumePiHistory(events(for: [file, file]))

        #expect(storage.attempts == 1)
        #expect(rig.services.startupIssues.count == 1)
    }
}

final class FailingWrites: PiIndexStorage, @unchecked Sendable {
    private(set) var attempts = 0
    func piSessions() async throws -> [StoredPiSession] { [] }
    func piCheckpoint(of session: String) async throws -> Data? { nil }
    func upsertPiSession(_ session: StoredPiSession, checkpoint: Data?) async throws {
        attempts += 1
        throw FlakyStorage.ReadFailed()
    }
}
#endif
