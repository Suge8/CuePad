#if os(macOS)
import CueTestSupport
import Foundation
import Synchronization
import Testing
import CueStore
@testable import CuePi

final class HistoryEventLog: Sendable {
    private let recorded = Mutex<[PiHistoryEvent]>([])
    /// 订阅的任务要引用自己，只能在初始化完成后起，所以放在锁里补上。
    private let task = Mutex<Task<Void, Never>?>(nil)

    /// `live` 是在线会话的文件（桥给的，`PiBridge.sessionFiles`）；只看回填的不给。
    init(_ indexer: PiHistoryIndexer, following live: some AsyncSequence<Set<URL>, Never> & Sendable = AsyncStream { $0.finish() }) {
        let stream = indexer.events(following: live, scope: .all)
        task.withLock { $0 = Task { [weak self] in for await e in stream { self?.recorded.withLock { $0.append(e) } } } }
    }
    deinit { task.withLock { $0?.cancel() } }

    var events: [PiHistoryEvent] { recorded.withLock { $0 } }
    var updates: [PiHistoryUpdate] { events.compactMap { if case .updated(let u) = $0 { u } else { nil } } }
    var finishedBackfill: Bool { events.contains { if case .backfillFinished = $0 { true } else { false } } }
}

struct HistoryIndexerTests {
    /// Pi 的会话目录（Codex 的用例把它当 `CODEX_HOME/sessions`）
    let root: URL
    init() throws {
        root = try makeTempDirectory().appending(path: "sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    private func makeSession(_ project: String, _ name: String, prompt: String, modified: Date) throws -> SessionFile {
        let dir = root.appending(path: project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var f = SessionFile(directory: dir, name: name)
        try f.append(SessionFile.header(id: name), SessionFile.user("u", nil, prompt, at: 1), SessionFile.assistant("a", "u", text: "r-\(prompt)", at: 2))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: f.url.path)
        return f
    }

    @Test func backfillIsNewestFirstSkipsUpToDateFilesAndSignalsCompletion() async throws {
        let now = Date()
        try makeSession("p1", "a.jsonl", prompt: "old", modified: now.addingTimeInterval(-300))
        let upToDate = try makeSession("p2", "b.jsonl", prompt: "known", modified: now.addingTimeInterval(-200))
        try makeSession("p2", "c.jsonl", prompt: "new", modified: now.addingTimeInterval(-100))
        // 上次读完时记下的修改时间与文件现在的一样：回填认得出它没动过
        let modified = try upToDate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let known = try PiHistory.index(file: upToDate.url, agent: .pi, from: nil, modified: modified, files: scratchFiles).checkpoint

        let log = HistoryEventLog(PiHistoryIndexer(sessions: root) { url in url.lastPathComponent == "b.jsonl" ? PiHistoryStart(checkpoint: known, hasTranscript: true) : nil })
        try await eventually("回填完成") { log.finishedBackfill }
        #expect(log.updates.map { $0.file.lastPathComponent } == ["c.jsonl", "a.jsonl"])
        // 完成信号在全部回填更新之后
        if case .backfillFinished = log.events.last! {} else { Issue.record("backfillFinished 应是最后一个事件") }
    }

    /// 与 Pi 的会话列表一致：只认 `<root>/<项目目录>/*.jsonl`。子代理会话（FireCode 写在 `<项目目录>/subagents/`）不是历史会话。
    @Test func subagentSessionsAreNotHistoryLikePisSessionList() async throws {
        let top = try makeSession("p1", "a.jsonl", prompt: "top", modified: Date())
        try makeSession("p1/subagents", "w.jsonl", prompt: "worker", modified: Date())
        let (live, files) = AsyncStream<Set<URL>>.makeStream()
        let log = HistoryEventLog(PiHistoryIndexer(sessions: root), following: live)
        try await eventually("回填完成") { log.finishedBackfill }
        #expect(log.updates.map { $0.file.lastPathComponent } == ["a.jsonl"])
        guard case .backfillFinished(let found?) = log.events.last! else { Issue.record("backfillFinished 应是最后一个事件"); return }
        #expect(found.map(\.lastPathComponent) == [top.url.lastPathComponent])

        let worker = try makeSession("p1/subagents", "w2.jsonl", prompt: "worker 2", modified: Date())
        let later = try makeSession("p2", "b.jsonl", prompt: "later", modified: Date())
        files.yield([worker.url, later.url])
        try await eventually("之后的顶层会话被索引") { log.updates.contains { $0.file.lastPathComponent == "b.jsonl" } }
        #expect(!log.updates.contains { $0.file.path.contains("/subagents/") })
    }

    /// Codex 会话文件的一行（`{timestamp, type, payload}`）。
    private func codexLine(_ type: String, _ second: Int, _ payload: [String: Any]) -> Data {
        Data((SessionFile.line(["timestamp": SessionFile.stamp(second), "type": type, "payload": payload]) + "\n").utf8)
    }

    /// Codex 的常驻服务整段会话都开着会话文件写，文件先建出来、文件头（`session_meta`）随后才写：回填读到空文件不记成会话，
    /// 文件头与之后的每次追加都当场读到（歇下要等回答读到才算），只记成文件头里的那个会话，不按文件名多记一个。
    @Test(.timeLimit(.minutes(1)))
    func anOpenCodexSessionIsReadAsItIsWrittenAndOnlyUnderItsRealID() async throws {
        let day = root.appending(path: "2026/10/14")
        let url = day.appending(path: "rollout-2026-10-14T15-57-42-live.jsonl")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let log = HistoryEventLog(PiHistoryIndexer(sessions: root, agent: .codex), following: AsyncStream { $0.yield([url]) })
        try await eventually("回填完成") { log.finishedBackfill }
        #expect(log.updates.isEmpty)

        let live = try FileHandle(forWritingTo: url)
        defer { try? live.close() }
        try live.write(contentsOf: codexLine("session_meta", 1, ["id": "live", "cwd": "/work"]))
        try await eventually("开着写的会话被索引") { log.updates.contains { $0.history.sessionID == "live" } }

        try live.write(contentsOf: codexLine("event_msg", 9, ["type": "task_started"]))
        try await eventually("开着写的会话之后的追加被索引") {
            log.updates.contains { $0.history.sessionID == "live" && $0.history.lastActivity == SessionFile.date(9) }
        }
        #expect(log.updates.allSatisfy { $0.sessionID == "live" })
    }

    /// 新用户常见顺序是先开 CuePad、后装 Pi：桥报出会话时它的文件连同会话目录都还不存在（Pi 第一条回答落盘前不建文件）。
    /// 之后建出目录、写入会话（会话还没结束），历史要当场跟上；目录被删掉再建也要恢复。
    @Test(.timeLimit(.minutes(1)))
    func aLiveSessionsFileIsReadOnceItAppearsUnderADirectoryCreatedLater() async throws {
        let sessions = root.appending(path: "agent/sessions")  // 连上层目录也还不存在
        let project = sessions.appending(path: "--work-x--")
        let files = [project.appending(path: "a.jsonl"), project.appending(path: "b.jsonl")]
        let log = HistoryEventLog(PiHistoryIndexer(sessions: sessions), following: AsyncStream { $0.yield(Set(files)) })
        try await eventually("回填完成") { log.finishedBackfill }

        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var first = SessionFile(directory: project, name: "a.jsonl")
        try first.append(SessionFile.header(id: "a"), SessionFile.user("u", nil, "after pi was installed", at: 1))
        try await eventually("后建目录里的会话被索引") {
            log.updates.contains { $0.history.displayName == "after pi was installed" }
        }

        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var second = SessionFile(directory: project, name: "b.jsonl")
        try second.append(SessionFile.header(id: "b"), SessionFile.user("u", nil, "after the directory came back", at: 1))
        try await eventually("删掉再建的目录里的会话被索引") {
            log.updates.contains { $0.history.displayName == "after the directory came back" }
        }
    }

}
#endif
