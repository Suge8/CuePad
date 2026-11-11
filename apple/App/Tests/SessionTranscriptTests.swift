#if os(macOS)
import CueStore
@testable import CueBridge
import Foundation
import Synchronization
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SessionTranscriptTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private func line(_ id: String, _ parent: String?, at: Date, user text: String) -> String {
        #"{"type":"message","id":"\#(id)","parentId":\#(parent.map { "\"\($0)\"" } ?? "null"),"timestamp":"\#(at.formatted(Self.iso))","message":{"role":"user","content":"\#(text)","timestamp":1}}"#
    }

    private func line(_ id: String, _ parent: String, at: Date, reply text: String) -> String {
        #"{"type":"message","id":"\#(id)","parentId":"\#(parent)","timestamp":"\#(at.formatted(Self.iso))","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"\#(text)"}],"timestamp":2}}"#
    }

    private func sessionFile(_ sessionID: String, at: Date) throws -> URL {
        let directory = rig.piPaths.sessionsDirectory.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(sessionID).jsonl")
        let lines = [
            #"{"type":"session","version":3,"id":"\#(sessionID)","timestamp":"\#(at.formatted(Self.iso))","cwd":"/work/x"}"#,
            line("u1", nil, at: at, user: "第一问"),
            line("a1", "u1", at: at.addingTimeInterval(1), reply: "第一答"),
            line("u2", "a1", at: at.addingTimeInterval(2), user: "第二问"),
            line("a2", "u2", at: at.addingTimeInterval(3), reply: "第二答"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(3)], ofItemAtPath: url.path)
        return url
    }

    private func backfill() async {
        let indexer = HistoryIndexer(
            agent: .pi, paths: AgentPaths(pi: rig.piPaths), transcriptWindow: Chat.transcriptWindow, files: store.files
        ) { [services] in await services.loadHistoryStart(for: $0) }!
        let source = indexer.events(following: AsyncStream { $0.finish() }, scope: .all)
        let events = AsyncStream<HistoryEvent> { continuation in
            let task = Task {
                for await event in source {
                    continuation.yield(event)
                    if case .backfillFinished = event { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        await services.consumeHistory(events, agent: .pi)
    }

    private func live(_ sessionID: String, file: URL) async throws -> CueBridge.Session {
        let session = CueBridge.Session(
            id: "\(sessionID).100", sessionID: sessionID, agent: .pi, sessionFile: file, pid: 100, cwd: URL(filePath: "/work/x", directoryHint: .isDirectory),
            terminal: TerminalIdentity(), state: .thinking, stateSince: .now)
        try await services.consumeSessionChanges(AsyncStream { continuation in
            continuation.yield(.appeared(session))
            continuation.finish()
        })
        return session
    }

    private func record(_ sessionID: String) async throws -> SessionState {
        try #require(try await store.allSessionStates().first { $0.sessionID == sessionID })
    }

    @Test func 近7天活跃的会话写出全部消息_更早的只写摘要_摘要与对话一致() async throws {
        _ = try sessionFile("recent", at: .now.addingTimeInterval(-3_600))
        _ = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))

        await backfill()

        let messages = try await store.chatMessages(of: "recent")
        #expect(messages.map(\.text) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(messages.map(\.role) == [.known(.user), .known(.pi), .known(.user), .known(.pi)])
        #expect(try await store.chatMessages(of: "old").isEmpty)
        for sessionID in ["recent", "old"] {
            let state = try await record(sessionID)
            #expect(state.lastPrompt == "第二问" && state.lastReply == "第二答" && state.pendingPrompt == nil)
        }
    }

    @Test func 七天外的会话按需补写_手机打开时发的请求由这台Mac从会话文件写出对话() async throws {
        _ = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))
        await backfill()
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }

        let request = try await store.requestTranscript(of: try await record("old"))
        let finished = try await eventually(store, { try $0.deliveryRequest(request.id) }, until: { $0?.isOpen == false })
        #expect(finished?.status == .known(.succeeded))

        #expect(try await store.chatMessages(of: "old").map(\.text) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    @Test func 补写请求还没被领取时再打开会话_不写第二条() async throws {
        _ = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))
        await backfill()
        let session = try await record("old")

        let first = try await services.requestTranscript(of: session)
        let late = first.createdAt.addingTimeInterval(Speech.receiptLimit + 1)
        #expect(Speech.trip(first, at: .always(at: late)).inTransit)  // 没人领取不算未确认：领取只在期限前，到期才是失败
        let again = try await services.requestTranscript(of: session)

        #expect(again.id == first.id)
        #expect(try await store.deliveryRequests(toSession: "old").filter { $0.mode == .known(.transcript) }.count == 1)
    }

    /// 不能只有近七天的会话更新、同一界面留着两种口径。
    @Test func 检查点作废后从头重读_七天外存着对话的会话也更新已存消息的工具计数() async throws {
        let at = Date.now.addingTimeInterval(-10 * 86_400)
        let directory = rig.piPaths.sessionsDirectory.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "old.jsonl")
        func stamp(_ seconds: Double) -> String { at.addingTimeInterval(seconds).formatted(Self.iso) }
        let lines = [
            #"{"type":"session","version":3,"id":"old","timestamp":"\#(stamp(0))","cwd":"/work/x"}"#,
            line("u1", nil, at: at, user: "跑一下"),
            #"{"type":"message","id":"t1","parentId":"u1","timestamp":"\#(stamp(1))","message":{"role":"assistant","stopReason":"toolUse","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"false"}}],"timestamp":2}}"#,
            #"{"type":"message","id":"r1","parentId":"t1","timestamp":"\#(stamp(2))","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","isError":true,"content":[{"type":"text","text":"exit 1"}],"timestamp":3}}"#,
            line("a1", "r1", at: at.addingTimeInterval(3), reply: "没通过"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: at.addingTimeInterval(3)], ofItemAtPath: file.path)
        let stale = ChatMessage(
            sessionID: "old", entryID: "a1", seq: 2, role: .pi, text: "没通过", at: at.addingTimeInterval(3),
            tools: .init(items: [.init(kind: .command, target: "false", failed: true)]), roundStartedAt: at)
        try await store.writeTranscript(SessionTranscript(sessionID: "old", messages: [stale], recap: Recap()))
        let real = realpath(file.path, nil)!
        defer { free(real) }
        try await store.upsertSession(
            IndexedSession(id: "old", path: String(cString: real), cwd: "/work/x", lastActivityAt: at, agent: .pi), checkpoint: Data("旧格式".utf8),
            host: TestApp.hostID)

        await backfill()

        let reply = try #require(try await store.chatMessages(of: "old").first { $0.role == .known(.pi) })
        #expect(reply.tools?.steps == 1 && reply.tools?.steps == reply.tools?.items.count)
    }

    @Test func 状态变化不改摘要_会话结束后没有进行中的提问() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        try FileManager.default.removeItem(at: file)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date.now
        try ([
            #"{"type":"session","version":3,"id":"s1","timestamp":"\#(now.formatted(Self.iso))","cwd":"/work/x"}"#,
            line("u1", nil, at: now, user: "做到一半"),
        ].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let session = try await live("s1", file: file)
        await backfill()
        #expect(try await record("s1").pendingPrompt == "做到一半")

        var idle = session
        idle.state = .settled
        try await services.consumeSessionChanges(AsyncStream { continuation in
            continuation.yield(.stateChanged(idle, from: .thinking))
            continuation.yield(.ended(idle, reason: .closed(reason: "quit")))
            continuation.finish()
        })
        try await StateRecorder(store: store, hostID: TestApp.hostID).end(sessionID: "s1")  // 托管的进程退出只是歇着，结束要你来
        #expect(try await record("s1").pendingPrompt == nil)

        await services.consumeHistory(AsyncStream { continuation in
            continuation.yield(.updated(try! History.index(file: file, agent: .pi, from: nil, files: store.files)))
            continuation.finish()
        }, agent: .pi)
        let ended = try await record("s1")
        #expect(ended.pendingPrompt == nil && ended.state == .known(.ended))
    }

    /// 文件一追加就写：Mac 本机界面也读同步记录，这里的延迟就是 Mac 上看到的延迟。
    @Test func 文件追加一条用户消息后_摘要与消息随即可读() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        _ = try await live("s1", file: file)
        let indexer = HistoryIndexer(agent: .pi, paths: AgentPaths(pi: rig.piPaths), files: store.files) { _ in nil }!
        let consuming = Task { await services.consumeHistory(indexer.events(following: AsyncStream { $0.yield([file]) }, scope: .all), agent: .pi) }
        defer { await consuming.stop() }
        _ = try await eventually(store, { try $0.chatMessages(of: "s1").count }, until: { $0 == 4 })

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("u3", "a2", at: .now, user: "第三问") + "\n").utf8))
        try handle.close()

        _ = try await eventually(store, {
            try $0.chatMessages(of: "s1").last?.text == "第三问" && $0.allSessionStates().first?.pendingPrompt == "第三问"
        }) { $0 }
    }

    @Test func 重启后会话重新连上_正在处理的提问仍在() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("u3", "a2", at: .now, user: "第三问") + "\n").utf8))
        try handle.close()
        _ = try await live("s1", file: file)
        await backfill()
        #expect(try await record("s1").pendingPrompt == "第三问")

        try services.reconcileLaunch()  // 重启时的启动对账
        _ = try await live("s1", file: file)  // 桥重新发现它；文件没有新内容，不会再读

        #expect(try await record("s1").pendingPrompt == "第三问")
    }

    @Test func 一直开着的Mac每天清理一次对话() async throws {
        let old = try sessionFile("old", at: .now.addingTimeInterval(-30 * 86_400))
        await backfill()
        try await store.writeTranscript(try History.index(file: old, agent: .pi, from: nil, files: store.files).transcript)
        #expect(try await store.chatMessages(of: "old").count == 4)

        let days = Mutex(0)
        let timing = Timing(now: { Date.now.addingTimeInterval(Double(days.withLock { $0 }) * 86_400) }) { _ in
            days.withLock { $0 += 8 }  // 睡一觉醒来已过了 8 天
            if days.withLock({ $0 }) > 8 { try await Task.sleep(for: .seconds(3_600)) }
        }
        let pruning = Task { await services.historyStore.keepPruned(timing: timing) }
        defer { await pruning.stop() }

        _ = try await eventually(store, { try $0.chatMessages(of: "old").count }, until: { $0 == 0 })
    }
}
#endif
