#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 造 Pi 会话 JSONL（v3 树结构）的最小写手。字段名来自 Pi 的 session-format 文档。
struct SessionFile {
    let url: URL
    private var lines: [String] = []

    init(directory: URL, name: String = "session.jsonl") {
        url = directory.appending(path: name)
    }

    static func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    static func header(id: String = "sess-1", cwd: String = "/work/x") -> String {
        line(["type": "session", "version": 3, "id": id, "timestamp": stamp(0), "cwd": cwd])
    }

    /// 第 n 秒：2026-01-01T00:00:0n.000Z
    static func stamp(_ second: Int) -> String { String(format: "2026-01-01T00:%02d:%02d.000Z", second / 60, second % 60) }
    static func date(_ second: Int) -> Date { Date(timeIntervalSince1970: 1_767_225_600 + Double(second)) }

    static func user(_ id: String, _ parent: String?, _ content: Any, at second: Int) -> String {
        line(["type": "message", "id": id, "parentId": parent as Any? ?? NSNull(), "timestamp": stamp(second),
              "message": ["role": "user", "content": content, "timestamp": second]])
    }

    static func assistant(_ id: String, _ parent: String, text: String?, stop: String = "stop", error: String? = nil, at second: Int) -> String {
        var message: [String: Any] = ["role": "assistant", "stopReason": stop, "timestamp": second,
                                      "content": text.map { [["type": "text", "text": $0]] } ?? []]
        if stop == "toolUse" {
            message["content"] = (message["content"] as! [[String: Any]]) + [["type": "toolCall", "id": "c", "name": "bash", "arguments": [:]]]
        }
        if let error { message["errorMessage"] = error }
        return line(["type": "message", "id": id, "parentId": parent, "timestamp": stamp(second), "message": message])
    }

    static func toolResult(_ id: String, _ parent: String, at second: Int) -> String {
        line(["type": "message", "id": id, "parentId": parent, "timestamp": stamp(second),
              "message": ["role": "toolResult", "toolCallId": "c", "toolName": "bash", "isError": false, "timestamp": second,
                          "content": [["type": "text", "text": String(repeating: "out ", count: 50)]]]])
    }

    /// `cuepad_show` 工具的结果：成功时 `details.preview` 是 CuePad 给的预览 id；`padding` 把整行撑过 512 字节（大行不做 JSON 解码的快路径）
    static func previewResult(_ id: String, _ parent: String, preview: String?, tool: String = "cuepad_show", isError: Bool = false, padding: Int = 0, at second: Int) -> String {
        var message: [String: Any] = [
            "role": "toolResult", "toolCallId": "c", "toolName": tool, "isError": isError, "timestamp": second,
            "content": [["type": "text", "text": "已发到手机：登录页" + String(repeating: "。", count: padding)]],
        ]
        if let preview { message["details"] = ["preview": preview] }
        return line(["type": "message", "id": id, "parentId": parent, "timestamp": stamp(second), "message": message])
    }

    static func compaction(_ id: String, _ parent: String, tokensBefore: Int?, at second: Int) -> String {
        var entry: [String: Any] = ["type": "compaction", "id": id, "parentId": parent, "timestamp": stamp(second), "summary": "摘要", "firstKeptEntryId": parent]
        if let tokensBefore { entry["tokensBefore"] = tokensBefore }
        return line(entry)
    }

    static func entry(_ type: String, _ id: String, _ parent: String, at second: Int, _ fields: [String: Any]) -> String {
        line(fields.merging(["type": type, "id": id, "parentId": parent, "timestamp": stamp(second)]) { a, _ in a })
    }

    static func info(_ id: String, _ parent: String, name: String, at second: Int) -> String {
        line(["type": "session_info", "id": id, "parentId": parent, "timestamp": stamp(second), "name": name])
    }

    mutating func append(_ newLines: String...) throws {
        lines += newLines
        try write(text: lines.joined(separator: "\n") + "\n")
    }

    func write(text: String) throws { try text.write(to: url, atomically: true, encoding: .utf8) }

    func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    var text: String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
}

struct HistoryTests {
    let dir: URL
    init() throws { dir = try makeTempDirectory() }

    private func index(_ file: SessionFile, from checkpoint: PiHistoryCheckpoint? = nil) throws -> PiHistoryUpdate {
        try PiHistory.index(file: file.url, from: checkpoint)
    }

    // MARK: 会话标题：与活动会话、Pi 会话列表同一规则（名字 → 文件里首条用户消息 → 工作目录名）

    @Test func titleIsTheFirstUserMessageInFileOrderLikePisSessionList() throws {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(cwd: "/work/proj"),
            SessionFile.user("u1", nil, "first prompt", at: 1),
            SessionFile.assistant("a1", "u1", text: "reply one", at: 2),
            SessionFile.user("u2", "a1", "later prompt", at: 3),
            SessionFile.assistant("t2", "u2", text: "checking", stop: "toolUse", at: 4),
            SessionFile.toolResult("r2", "t2", at: 5),
            SessionFile.user("u0", nil, "rewritten first", at: 6))  // 回到开头另起分支：Pi 的列表仍取文件里的第一条
        #expect(try index(f).history.displayName == "first prompt")

        try f.append(SessionFile.info("n1", "u0", name: "Refactor auth", at: 7))
        #expect(try index(f).history.displayName == "Refactor auth")
    }

    @Test func titleJoinsTextBlocksIntoOneLine() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(), SessionFile.user("u1", nil, [
            ["type": "text", "text": "  line one"], ["type": "image", "data": "AAAA", "mimeType": "image/png"],
            ["type": "text", "text": "line two \n"],
        ], at: 1))
        #expect(try index(f).history.displayName == "line one line two")
    }

    @Test func sessionWithoutMessagesIsTitledByItsFolder() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(cwd: "/work/proj"))
        #expect(try index(f).history.displayName == "proj")
    }

    @Test func exposesHeaderNameAndLastActivity() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(id: "abc", cwd: "/work/proj"), SessionFile.user("u1", nil, "p", at: 1),
                     SessionFile.info("n1", "u1", name: "old", at: 2), SessionFile.info("n2", "n1", name: "Refactor auth", at: 9))
        let h = try index(f).history
        #expect(h.sessionID == "abc" && h.cwd == "/work/proj" && h.name == "Refactor auth")
        #expect(h.lastActivity == SessionFile.date(9))
    }

    // MARK: 命令在会话文件里留下的

    /// 对话只来自会话文件，与终端一致：压缩留下一条 compaction（终端里是压缩摘要那一行），对话里是一行系统行；
    /// 换模型、改强度、改名只是设置条目，终端的对话里没有它们，这里也没有；模板与 skill 展开成一条普通的用户消息（没有投送请求 id）。
    @Test func compactionIsASystemLineAndSettingEntriesAreNotConversation() throws {
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(),
            SessionFile.user("u1", nil, "first", at: 1),
            SessionFile.assistant("a1", "u1", text: "reply one", at: 2),
            SessionFile.entry("model_change", "m1", "a1", at: 3, ["provider": "fake", "modelId": "echo-b"]),
            SessionFile.entry("thinking_level_change", "t1", "m1", at: 4, ["thinkingLevel": "high"]),
            SessionFile.info("n1", "t1", name: "改名", at: 5),
            SessionFile.compaction("c1", "n1", tokensBefore: 63_000, at: 6),
            SessionFile.compaction("c2", "c1", tokensBefore: 950, at: 7),
            SessionFile.compaction("c3", "c2", tokensBefore: nil, at: 8),
            SessionFile.user("u2", "c3", "Say hello to world.", at: 9))

        let update = try index(f)

        #expect(update.transcript.map(\.role) == [.user, .pi, .system, .system, .system, .user])
        #expect(update.transcript[2...4].map(\.text) == ["已压缩上下文 · 压缩前约 63k tokens", "已压缩上下文 · 压缩前约 950 tokens", "已压缩上下文"])
        #expect(update.transcript[2].entryID == "c1" && update.transcript[2].seq == 7 && update.transcript[2].at == SessionFile.date(6))
        #expect(update.transcript[5].text == "Say hello to world." && update.transcript[5].deliveryID == nil)
        #expect(update.recap.lastReply == "reply one" && update.recap.pendingPrompt == "Say hello to world.")  // 系统行不动问答摘要
    }

    // MARK: 发给手机的预览

    /// `cuepad_show` 工具成功的那一行（它的结果带着预览 id）在对话里成为一条预览，位置就是它在会话文件里的位置；
    /// 失败的调用、别的工具的结果不是。行再长也一样认得出。
    @Test func aSuccessfulShowToolResultIsAPreviewEntryAtItsPlaceInTheFile() throws {
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        var f = SessionFile(directory: dir)
        try f.append(
            SessionFile.header(),
            SessionFile.user("u1", nil, "给我看看登录页", at: 1),
            SessionFile.assistant("a1", "u1", text: nil, stop: "toolUse", at: 2),
            SessionFile.previewResult("t1", "a1", preview: first, at: 3),
            SessionFile.assistant("a2", "t1", text: nil, stop: "toolUse", at: 4),
            SessionFile.previewResult("t2", "a2", preview: second, padding: 700, at: 5),
            SessionFile.assistant("a3", "t2", text: nil, stop: "toolUse", at: 6),
            SessionFile.previewResult("t3", "a3", preview: nil, isError: true, at: 7),
            SessionFile.assistant("a4", "t3", text: nil, stop: "toolUse", at: 8),
            SessionFile.previewResult("t4", "a4", preview: UUID().uuidString, tool: "bash", at: 9),
            SessionFile.assistant("a5", "t4", text: "发给你了", at: 10))

        let update = try index(f)

        #expect(update.transcript.map(\.role) == [.user, .preview, .preview, .pi])
        #expect(update.transcript[1...2].map(\.text) == [first, second])
        #expect(update.transcript[1].entryID == "t1" && update.transcript[1].seq == 4 && update.transcript[1].at == SessionFile.date(3))
        #expect(update.transcript[3].toolCount == 4)  // 预览不改这一轮的工具数与问答摘要
        #expect(update.recap.lastReply == "发给你了")
    }

    // MARK: 增量

    @Test func resumingFromACheckpointEqualsIndexingTheWholeFileAndOnlyReadsNewBytes() throws {
        var f = SessionFile(directory: dir)
        let lines = [
            SessionFile.header(), SessionFile.user("u1", nil, "one", at: 1), SessionFile.assistant("a1", "u1", text: "r1", at: 2),
            SessionFile.user("u2", "a1", "two", at: 3), SessionFile.assistant("a2", "u2", text: "r2", stop: "toolUse", at: 4),
            SessionFile.toolResult("t2", "a2", at: 5), SessionFile.assistant("a3", "t2", text: "final", at: 6),
        ]
        var checkpoint: PiHistoryCheckpoint?
        var consumed: UInt64 = 0
        for (i, line) in lines.enumerated() {
            try f.append(line)
            let update = try index(f, from: checkpoint)
            // 检查点必须能落盘再读回（调用方存进 Store）
            checkpoint = try JSONDecoder().decode(PiHistoryCheckpoint.self, from: JSONEncoder().encode(update.checkpoint))
            #expect(update.bytesRead == line.utf8.count + 1, "第 \(i) 步只读新增字节")
            consumed += UInt64(update.bytesRead)
            #expect(update.checkpoint.offset == consumed)
        }
        let full = try index(f).history
        #expect(try index(f, from: checkpoint).history == full)
        #expect(full.displayName == "one" && full.lastActivity == SessionFile.date(6))
    }

    @Test func unchangedFileReadsNothing() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(), SessionFile.user("u1", nil, "p", at: 1))
        let first = try index(f)
        let again = try index(f, from: first.checkpoint)
        #expect(again.bytesRead == 0)
        #expect(again.history == first.history)
    }

    @Test func halfWrittenLineIsNotConsumedUntilItsNewlineArrives() throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header())
        let base = try index(f)
        let prompt = SessionFile.user("u1", nil, "whole prompt", at: 2)
        let cut = prompt.index(prompt.startIndex, offsetBy: prompt.count / 2)
        try f.appendRaw(String(prompt[..<cut]))

        let partial = try index(f, from: base.checkpoint)
        #expect(partial.bytesRead == 0 && partial.checkpoint.offset == base.checkpoint.offset)
        #expect(partial.history.firstMessage == nil)

        try f.appendRaw(String(prompt[cut...]) + "\n")
        let done = try index(f, from: partial.checkpoint)
        #expect(done.history.displayName == "whole prompt")
        #expect(done.bytesRead == prompt.utf8.count + 1)
    }

    @Test func corruptAndBlankLinesAreSkipped() throws {
        let f = SessionFile(directory: dir)
        try f.write(text: [SessionFile.header(), "{not json", "", SessionFile.user("u1", nil, "p", at: 1), "[1,2]"].joined(separator: "\n") + "\n")
        #expect(try index(f).history.displayName == "p")
    }

    @Test(arguments: ["shorter", "same-size-different-content"])
    func replacedFileIsRebuiltInsteadOfResumedFromAStaleOffset(kind: String) throws {
        var f = SessionFile(directory: dir)
        try f.append(SessionFile.header(id: "old"), SessionFile.user("u1", nil, "old prompt that is fairly long", at: 1),
                     SessionFile.assistant("a1", "u1", text: "old reply", at: 2))
        let old = try index(f)

        let replacement: [String] = kind == "shorter"
            ? [SessionFile.header(id: "new"), SessionFile.user("x1", nil, "n", at: 1)]
            : [SessionFile.header(id: "new"), SessionFile.user("x1", nil, "new prompt that is fairly long", at: 1),
               SessionFile.assistant("y1", "x1", text: "new reply", at: 2)]
        try f.write(text: replacement.joined(separator: "\n") + "\n")

        let rebuilt = try index(f, from: old.checkpoint)
        #expect(rebuilt.history == (try index(f)).history)
        #expect(rebuilt.history.sessionID == "new")
    }

    @Test func missingFileThrowsSoCallersCanWaitForTheFirstMessage() throws {
        var f = SessionFile(directory: dir, name: "later.jsonl")
        #expect(throws: (any Error).self) { try PiHistory.index(file: f.url, from: nil) }
        try f.append(SessionFile.header(), SessionFile.user("u1", nil, "p", at: 1)) // 首条消息落盘后同一路径可索引
        #expect(try index(f).history.displayName == "p")
    }
}

// MARK: - 只读摘要：首次回填 7 天外的会话不解析对话

struct HistorySummaryOnlyTests {
    let dir: URL
    init() throws { dir = try makeTempDirectory() }

    /// 各种会话形状：做完的几轮、中途改名、机器消息触发的轮、在跑的一轮（已调工具、你说的话还在等）、上次中途退出的一轮。
    private func shapes() throws -> [SessionFile] {
        var done = SessionFile(directory: dir, name: "done.jsonl")
        try done.append(
            SessionFile.header(id: "done"), SessionFile.user("u1", nil, "第一问", at: 1),
            SessionFile.assistant("t1", "u1", text: "先看看", stop: "toolUse", at: 2), SessionFile.toolResult("r1", "t1", at: 3),
            SessionFile.assistant("a1", "r1", text: "第一答", at: 4), SessionFile.info("i1", "a1", name: "改过的名字", at: 5),
            SessionFile.user("u2", "i1", "<some_event>\n子任务完成\n</some_event>", at: 6), SessionFile.assistant("a2", "u2", text: "汇报", at: 7),
            SessionFile.info("i2", "a2", name: "最后的名字", at: 8))
        var running = SessionFile(directory: dir, name: "running.jsonl")
        try running.append(
            SessionFile.header(id: "running"), SessionFile.user("u1", nil, "第一问", at: 1), SessionFile.assistant("a1", "u1", text: "第一答", at: 2),
            SessionFile.user("u2", "a1", "第二问", at: 3), SessionFile.assistant("t2", "u2", text: nil, stop: "toolUse", at: 4),
            SessionFile.toolResult("r2", "t2", at: 5), SessionFile.user("u3", "r2", "顺便再看下日志", at: 6),
            SessionFile.assistant("t3", "u3", text: nil, stop: "toolUse", at: 7))
        var empty = SessionFile(directory: dir, name: "empty.jsonl")
        try empty.append(SessionFile.header(id: "empty"))
        var errored = SessionFile(directory: dir, name: "errored.jsonl")
        try errored.append(
            SessionFile.header(id: "errored"), SessionFile.user("u1", nil, [["type": "text", "text": "两块"], ["type": "text", "text": "文字"]], at: 1),
            SessionFile.assistant("a1", "u1", text: nil, stop: "error", error: "429", at: 2))
        return [done, running, empty, errored]
    }

    /// 只读摘要得到的检查点与逐行全读完全一样（之后增量读接得上），只是不给出对话。
    @Test func aSummaryOnlyReadEqualsAFullReadWithoutTheTranscript() throws {
        for file in try shapes() {
            let full = try PiHistory.index(file: file.url, from: nil)
            let summary = try PiHistory.index(file: file.url, from: nil, transcript: false)
            #expect(summary.checkpoint == full.checkpoint, "\(file.url.lastPathComponent)")
            #expect(summary.history == full.history && summary.transcript.isEmpty)
        }
    }

    @Test func aSessionReadForItsSummaryContinuesIncrementallyLikeAFullRead() throws {
        var file = try shapes()[1]
        let summary = try PiHistory.index(file: file.url, from: nil, transcript: false)
        try file.append(SessionFile.assistant("a3", "t3", text: "日志里没有异常", at: 8))

        let next = try PiHistory.index(file: file.url, from: summary.checkpoint)
        #expect(next.checkpoint == (try PiHistory.index(file: file.url, from: nil)).checkpoint)
        #expect(next.recap == PiTranscriptRecap(lastPrompt: "顺便再看下日志", lastReply: "日志里没有异常", pendingPrompt: nil))
        #expect(next.transcript.map(\.toolCount) == [2])
    }
}

// MARK: - 后台索引器：首次按修改时间倒序，之后跟随文件变化

/// 订阅索引器事件流并记录。
final class HistoryEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [PiHistoryEvent] = []
    private var task: Task<Void, Never>?

    init(_ indexer: PiHistoryIndexer) {
        let stream = indexer.events()
        task = Task { [weak self] in
            for await e in stream { self?.lock.withLock { self?._events.append(e) } }
        }
    }
    deinit { task?.cancel() }

    var events: [PiHistoryEvent] { lock.withLock { _events } }
    var updates: [PiHistoryUpdate] { events.compactMap { if case .updated(let u) = $0 { u } else { nil } } }
    var finishedBackfill: Bool { events.contains { if case .backfillFinished = $0 { true } else { false } } }
}

struct HistoryIndexerTests {
    let root: URL
    init() throws { root = try makeTempDirectory() }

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
        let known = try PiHistory.index(file: upToDate.url, from: nil).checkpoint

        let log = HistoryEventLog(PiHistoryIndexer(root: root) { url in url.lastPathComponent == "b.jsonl" ? known : nil })
        try await eventually("回填完成") { log.finishedBackfill }
        #expect(log.updates.map { $0.file.lastPathComponent } == ["c.jsonl", "a.jsonl"])
        // 完成信号在全部回填更新之后
        if case .backfillFinished = log.events.last! {} else { Issue.record("backfillFinished 应是最后一个事件") }
    }

    /// 与 Pi 的会话列表一致：只认 `<root>/<项目目录>/*.jsonl`。子代理会话（FireCode 写在 `<项目目录>/subagents/`）不是历史会话。
    @Test func subagentSessionsAreNotHistoryLikePisSessionList() async throws {
        let top = try makeSession("p1", "a.jsonl", prompt: "top", modified: Date())
        try makeSession("p1/subagents", "w.jsonl", prompt: "worker", modified: Date())
        let log = HistoryEventLog(PiHistoryIndexer(root: root) { _ in nil })
        try await eventually("回填完成") { log.finishedBackfill }
        #expect(log.updates.map { $0.file.lastPathComponent } == ["a.jsonl"])
        guard case .backfillFinished(let files) = log.events.last! else { Issue.record("backfillFinished 应是最后一个事件"); return }
        #expect(files.map(\.lastPathComponent) == [top.url.lastPathComponent])

        try makeSession("p1/subagents", "w2.jsonl", prompt: "worker 2", modified: Date())
        try makeSession("p2", "b.jsonl", prompt: "later", modified: Date())
        try await eventually("之后的顶层会话被索引") { log.updates.contains { $0.file.lastPathComponent == "b.jsonl" } }
        #expect(!log.updates.contains { $0.file.path.contains("/subagents/") })
    }

    /// 首次回填只为最近修改过（`transcriptWindow` 内）的会话解析对话；更早的只读摘要（按修改时间判断，不读内容）。
    @Test func backfillParsesTranscriptsOnlyForRecentlyModifiedSessions() async throws {
        let now = Date()
        try makeSession("p1", "recent.jsonl", prompt: "近的", modified: now.addingTimeInterval(-86_400))
        try makeSession("p1", "old.jsonl", prompt: "远的", modified: now.addingTimeInterval(-10 * 86_400))

        let log = HistoryEventLog(PiHistoryIndexer(root: root, transcriptWindow: 7 * 86_400) { _ in nil })
        try await eventually("回填完成") { log.finishedBackfill }

        let byName = Dictionary(uniqueKeysWithValues: log.updates.map { ($0.file.lastPathComponent, $0) })
        #expect(byName["recent.jsonl"]?.transcript.map(\.text) == ["近的", "r-近的"])
        #expect(byName["old.jsonl"]?.transcript.isEmpty == true)
        #expect(byName["old.jsonl"]?.recap == PiTranscriptRecap(lastPrompt: "远的", lastReply: "r-远的", pendingPrompt: nil))
    }

    @Test func liveAppendsAndNewFilesAreIndexedIncrementally() async throws {
        let f = try makeSession("p1", "a.jsonl", prompt: "first", modified: Date())
        // 调用方从不返回检查点：索引器自己对回填之后被触碰的文件保留，之后的增量不能退化成重读
        let log = HistoryEventLog(PiHistoryIndexer(root: root) { _ in nil })
        try await eventually("回填完成") { log.finishedBackfill }

        let firstAppend = [SessionFile.user("u2", "a", "second", at: 3), SessionFile.assistant("a2", "u2", text: "r2", at: 4)]
        try f.appendRaw(firstAppend.joined(separator: "\n") + "\n")
        try await eventually("第一次追加被索引") { log.updates.contains { $0.history.lastActivity == SessionFile.date(4) } }

        let secondAppend = SessionFile.user("u3", "a2", "third", at: 5)
        try f.appendRaw(secondAppend + "\n")
        try await eventually("第二次追加被索引") { log.updates.contains { $0.history.lastActivity == SessionFile.date(5) } }
        let update = try #require(log.updates.last)
        #expect(update.file.lastPathComponent == "a.jsonl")
        #expect(update.bytesRead == secondAppend.utf8.count + 1)
        #expect(update.history.displayName == "first")

        try makeSession("p3", "fresh.jsonl", prompt: "brand new", modified: Date())
        try await eventually("新文件被索引") { log.updates.contains { $0.file.lastPathComponent == "fresh.jsonl" } }
    }

    /// 新用户常见顺序是先开 CuePad、后装 Pi：开始监听时会话目录还不存在。之后建出目录、写入会话（会话还没结束），
    /// 历史要跟上；目录被删掉再建也要恢复。
    @Test(.timeLimit(.minutes(1)))
    func sessionsDirectoryCreatedAfterStartIsWatchedAndSurvivesRecreation() async throws {
        let sessions = root.appending(path: "agent/sessions")  // 连上层目录也还不存在
        let log = HistoryEventLog(PiHistoryIndexer(root: sessions) { _ in nil })
        try await eventually("回填完成") { log.finishedBackfill }

        let project = sessions.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var first = SessionFile(directory: project, name: "a.jsonl")
        try first.append(SessionFile.header(id: "a"), SessionFile.user("u", nil, "after pi was installed", at: 1))
        try await eventually("后建目录里的会话被索引", timeout: .seconds(5)) {
            log.updates.contains { $0.history.displayName == "after pi was installed" }
        }

        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var second = SessionFile(directory: project, name: "b.jsonl")
        try second.append(SessionFile.header(id: "b"), SessionFile.user("u", nil, "after the directory came back", at: 1))
        try await eventually("删掉再建的目录里的会话被索引", timeout: .seconds(5)) {
            log.updates.contains { $0.history.displayName == "after the directory came back" }
        }
    }

    @Test func callerSuppliedCheckpointMeansOnlyNewBytesAreRead() async throws {
        let f = try makeSession("p1", "a.jsonl", prompt: "first", modified: Date())
        let checkpoint = try PiHistory.index(file: f.url, from: nil).checkpoint
        let tail = SessionFile.user("u2", "a", "while app was closed", at: 3)
        try f.appendRaw(tail + "\n")

        let log = HistoryEventLog(PiHistoryIndexer(root: root) { _ in checkpoint })
        try await eventually("回填完成") { log.finishedBackfill }
        let update = try #require(log.updates.first)
        #expect(update.bytesRead == tail.utf8.count + 1)
        #expect(update.history.lastActivity == SessionFile.date(3) && update.history.displayName == "first")
    }
}
#endif
