#if os(macOS)
@testable import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 会话文件的形状照各家真机写下的（Claude Code 2.1、Grok 1.0、Codex 0.16x 的本机会话目录）。
@MainActor
@Suite(.releasesLibraries)
struct SessionTitleTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func lines(_ objects: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try objects.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) + "\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
    }

    private func indexed(_ file: URL, _ agent: AgentKind, id: String) async throws -> String {
        let update = try PiHistory.index(file: file, agent: agent, from: nil, files: store.files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(update)); $0.finish() }, agent: agent)
        return try #require(try await store.piSessions(sessionIDs: [id])[id]).name(at: app.services.speech)
    }

    private func claude(_ id: String, _ extra: [[String: Any]]) throws -> URL {
        let file = app.directory.appending(path: "claude/projects/-w/\(id).jsonl")
        let said: [String: Any] = [
            "type": "user", "uuid": "u1", "sessionId": id, "cwd": app.directory.path, "timestamp": Self.stamp.format(.now),
            "message": ["role": "user", "content": "帮我看看登录页为什么白屏"],
        ]
        try Self.lines([said] + extra, to: file)
        return file
    }

    @Test func ClaudeCode自己起的名字当会话名_你改过的名字为准() async throws {
        defer { app.services.cancelBackgroundWork() }
        let auto: [String: Any] = ["type": "ai-title", "aiTitle": "排查登录页白屏", "sessionId": "c1"]
        #expect(try await indexed(try claude("c1", [auto]), .claudeCode, id: "c1") == "排查登录页白屏")

        let mine: [String: Any] = ["type": "custom-title", "customTitle": "登录白屏", "sessionId": "c2"]
        let later: [String: Any] = ["type": "ai-title", "aiTitle": "排查登录页白屏", "sessionId": "c2"]
        #expect(try await indexed(try claude("c2", [mine, later]), .claudeCode, id: "c2") == "登录白屏", "你起的名字不被它后来起的盖过")

        #expect(try await indexed(try claude("c3", []), .claudeCode, id: "c3") == "帮我看看登录页为什么白屏", "没起名退回首句")
    }

    @Test func Codex与Grok的会话名在旁边的文件里_照样读到() async throws {
        defer { app.services.cancelBackgroundWork() }
        let codexHome = app.directory.appending(path: "codex")
        let rollout = codexHome.appending(path: "sessions/2026/11/06/rollout-2026-11-06T10-00-00-019ceba8-70da-7553-bd8c-d582636e029d.jsonl")
        let at = Self.stamp.format(.now)
        try Self.lines([
            ["timestamp": at, "type": "session_meta", "payload": ["id": "x1", "cwd": app.directory.path]],
            ["timestamp": at, "type": "event_msg", "payload": ["type": "item_completed", "item": [
                "type": "UserMessage", "id": "u1", "content": [["type": "text", "text": "把发版脚本改成并行"]]]]],
        ], to: rollout)
        try Self.lines([
            ["id": "x1", "thread_name": "发版并行", "updated_at": at],
            ["id": "x0", "thread_name": "别的会话", "updated_at": at],
            ["id": "x1", "thread_name": "发版脚本并行化", "updated_at": at],
        ], to: codexHome.appending(path: "session_index.jsonl"))
        #expect(try await indexed(rollout, .codex, id: "x1") == "发版脚本并行化", "改过名以最后一行为准")

        let grok = app.directory.appending(path: "grok/sessions/%2Fw/g1/updates.jsonl")
        try Self.lines([["timestamp": Date.now.timeIntervalSince1970, "method": "session/update", "params": [
            "sessionId": "g1", "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "生成一段 6 秒的黑屏视频"]]]]], to: grok)
        try JSONSerialization.data(withJSONObject: ["generated_title": "6 秒黑屏视频", "session_summary": "6 秒黑屏视频", "title_is_manual": false])
            .write(to: grok.deletingLastPathComponent().appending(path: "summary.json"))
        #expect(try await indexed(grok, .grok, id: "g1") == "6 秒黑屏视频")
    }

    @Test func 在线会话的名字只在文件里_读到后补上_不倒回接入报来的改名() async throws {
        defer { app.services.cancelBackgroundWork() }
        let events = app.pi.changes()
        let consume = Task { try await app.services.consumePiChanges(events) }
        defer { await consume.stop() }
        final class Link: SessionLink {}
        let file = try claude("c9", [])
        var live = PiSession(
            id: "c9.1", sessionID: "c9", agent: .claudeCode, sessionFile: file, pid: 1, cwd: app.directory, terminal: PiTerminal(),
            state: .settled, stateSince: .now)
        live.firstMessage = "帮我看看登录页为什么白屏"
        app.pi.attach(live, via: Link())
        let shown: @Sendable (isolated CueStore) throws -> String? = { try $0.piSessions(sessionIDs: ["c9"])["c9"]?.state.title }
        _ = try await eventually(store, shown) { $0 == "帮我看看登录页为什么白屏" }

        let first = try PiHistory.index(file: file, agent: .claudeCode, from: nil, files: store.files)
        try Self.lines([
            ["type": "user", "uuid": "u1", "sessionId": "c9", "cwd": app.directory.path, "timestamp": Self.stamp.format(.now),
             "message": ["role": "user", "content": "帮我看看登录页为什么白屏"]],
            ["type": "ai-title", "aiTitle": "排查登录页白屏", "sessionId": "c9"],
        ], to: file)
        let titled = try PiHistory.index(file: file, agent: .claudeCode, from: first.checkpoint, files: store.files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(titled)); $0.finish() }, agent: .claudeCode)
        _ = try await eventually(store, shown) { $0 == "排查登录页白屏" }
        let board = try await TaskBoard.read(from: store)
        #expect(board.advancing.first { $0.id == "session/c9" }?.loose?.name(at: app.services.speech) == "排查登录页白屏")

        app.pi.update(live.id) { $0.name = "登录白屏" }
        _ = try await eventually(store, shown) { $0 == "登录白屏" }
        let stale = try PiHistory.index(file: file, agent: .claudeCode, from: titled.checkpoint, files: store.files)
        await app.services.consumePiHistory(AsyncStream { $0.yield(.updated(stale)); $0.finish() }, agent: .claudeCode)
        #expect(app.pi.session(sessionID: "c9")?.name == "登录白屏", "文件还没写下改名：不倒回去")
        consume.cancel()
        _ = await consume.result
    }
    @Test func 只有旁边存名字的文件变了_名字照样跟上_重开后也是() async throws {
        defer { app.services.cancelBackgroundWork() }
        let paths = AgentPaths(pi: app.piPaths, environment: app.agentHomes)
        let file = GrokRuntime.sessionFile(in: paths.home(of: .grok), cwd: app.directory.path, id: "g2")
        try Self.lines([["timestamp": Date.now.timeIntervalSince1970, "method": "session/update", "params": [
            "sessionId": "g2", "update": ["sessionUpdate": "user_message_chunk", "content": ["type": "text", "text": "生成一段黑屏视频"]]]]], to: file)
        let summary = file.deletingLastPathComponent().appending(path: "summary.json")
        func title(_ name: String) throws {
            try JSONSerialization.data(withJSONObject: ["generated_title": name, "title_is_manual": false]).write(to: summary, options: .atomic)
        }
        let row: @Sendable (isolated CueStore) throws -> String? = { try $0.piSessions(sessionIDs: ["g2"])["g2"]?.state.title }
        func indexing(following live: Set<URL>) -> Task<Void, Never> {
            let indexer = PiHistoryIndexer(agent: .grok, paths: paths, files: store.files) { [services = app.services] in await services.loadHistoryStart(for: $0) }!
            return Task { [services = app.services] in
                await indexer.consuming(following: AsyncStream { $0.yield(live) }) { await services.consumePiHistory($0, agent: .grok) }
            }
        }

        try title("黑屏视频")
        let first = indexing(following: [file])
        _ = try await eventually(store, row) { $0 == "黑屏视频" }
        try title("6 秒黑屏视频")
        _ = try await eventually(store, row) { $0 == "6 秒黑屏视频" }
        first.cancel()
        _ = await first.value

        try title("纯黑静音视频")
        let again = indexing(following: [])
        defer { await again.stop() }
        _ = try await eventually(store, row) { $0 == "纯黑静音视频" }
    }
}
#endif
