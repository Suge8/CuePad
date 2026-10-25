#if os(macOS)
import CueStore
@testable import CuePi
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 会话对话：Mac 从会话文件写出——近 7 天活跃的会话自动写全部消息，更早的按需补写；会话记录上的摘要是同一次写入的投影；
/// 文件一变就写（不经状态记录器的节流）。
struct PiTranscriptTests {
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

    /// 像 App 启动时那样回填一次会话目录：索引器定要不要对话（最近 7 天修改过的、本机已存着对话的），落盘照 App 的路子走。
    private func backfill() async {
        let indexer = PiHistoryIndexer(
            agent: .pi, paths: AgentPaths(pi: rig.piPaths), transcriptWindow: PiHistoryPersistence.transcriptWindow, files: store.files
        ) { [services] in await services.loadHistoryStart(for: $0) }!
        let source = indexer.events(following: AsyncStream { $0.finish() }, scope: .all)
        let events = AsyncStream<PiHistoryEvent> { continuation in
            let task = Task {
                for await event in source {
                    continuation.yield(event)
                    if case .backfillFinished = event { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        await services.consumePiHistory(events, agent: .pi)
    }

    /// 桥上看到这个会话在线（状态记录器写出未结束的记录；不结束）。
    private func live(_ sessionID: String, file: URL) async throws -> CuePi.PiSession {
        let session = CuePi.PiSession(
            id: "\(sessionID).100", sessionID: sessionID, agent: .pi, sessionFile: file, pid: 100, cwd: URL(filePath: "/work/x", directoryHint: .isDirectory),
            terminal: PiTerminal(), state: .thinking, stateSince: .now)
        try await services.consumePiChanges(AsyncStream { continuation in
            continuation.yield(.appeared(session))
            continuation.finish()
        })
        return session
    }

    private func record(_ sessionID: String) async throws -> PiSessionState {
        try #require(try await store.allPiSessionStates().first { $0.sessionID == sessionID })
    }

    @Test func 近7天活跃的会话写出全部消息_更早的只写摘要_摘要与对话一致() async throws {
        _ = try sessionFile("recent", at: .now.addingTimeInterval(-3_600))
        _ = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))

        await backfill()

        let messages = try await store.piMessages(of: "recent")
        #expect(messages.map(\.text) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(messages.map(\.role) == [.known(.user), .known(.pi), .known(.user), .known(.pi)])
        #expect(try await store.piMessages(of: "old").isEmpty)
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
        for try await current in store.observe({ try $0.deliveryRequest(request.id) }) {
            if current?.status == .known(.succeeded) || current?.status == .known(.failed) {
                #expect(current?.status == .known(.succeeded))
                break
            }
        }

        #expect(try await store.piMessages(of: "old").map(\.text) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(try RawDB(services.location.databaseURL).count("sendRecords") == 0)
    }

    /// 会话所在的 Mac 没回应：补写请求在页面上超时；再打开会话不写第二条，那台 Mac 醒来领取那一条就够。
    @Test func 补写请求还没被领取时再打开会话_不写第二条() async throws {
        _ = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))
        await backfill()
        let session = try await record("old")

        let first = try await services.requestTranscript(of: session)
        let late = first.createdAt.addingTimeInterval(Speech.receiptLimit + 1)
        #expect(Speech.trip(first, at: .always(at: late)).failure != nil)  // 页面上已是没能送达（这里没有同步：一直没发出）
        let again = try await services.requestTranscript(of: session)

        #expect(again.id == first.id)
        #expect(try await store.deliveryRequests(toSession: "old").filter { $0.mode == .known(.transcript) }.count == 1)
    }

    /// 工具计数口径变了、会话文件检查点作废后从头重读：七天外却还存着对话的会话（仍被提示词引用而没清掉）也要把已存的消息重写成新口径，
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
        // 旧口径存下的回答：失败的命令不在各类计数里
        let stale = PiChatMessage(
            sessionID: "old", entryID: "a1", seq: 2, role: .pi, text: "没通过", at: at.addingTimeInterval(3),
            tools: .init(items: [.init(kind: .command, target: "false", failed: true)]), roundStartedAt: at)
        try await store.writePiTranscript(PiTranscript(sessionID: "old", messages: [stale], recap: PiRecap()))
        // 旧口径时索引过它：会话行在（索引器认的是真实路径），检查点格式已作废
        let real = realpath(file.path, nil)!
        defer { free(real) }
        try await store.upsertPiSession(
            IndexedSession(id: "old", path: String(cString: real), cwd: "/work/x", lastActivityAt: at, agent: .pi), checkpoint: Data("旧格式".utf8),
            host: TestApp.hostID)

        await backfill()

        let reply = try #require(try await store.piMessages(of: "old").first { $0.role == .known(.pi) })
        #expect(reply.tools?.steps == 1 && reply.tools?.steps == reply.tools?.items.count)
    }

    /// 摘要只有对话这一个写者：Pi 桥上的状态变化不改它。
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
        try await services.consumePiChanges(AsyncStream { continuation in
            continuation.yield(.stateChanged(idle, from: .thinking))
            continuation.yield(.ended(idle, reason: .closed(reason: "quit")))
            continuation.finish()
        })
        #expect(try await record("s1").pendingPrompt == nil)

        // 文件从头再读一遍：已结束的会话不会重新有进行中的提问
        await services.consumePiHistory(AsyncStream { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, agent: .pi, from: nil, files: store.files)))
            continuation.finish()
        }, agent: .pi)
        let ended = try await record("s1")
        #expect(ended.pendingPrompt == nil && ended.state == .known(.ended))
    }

    /// 文件一追加就写：Mac 本机界面也读同步记录，这里的延迟就是 Mac 上看到的延迟。
    @Test func 文件追加一条用户消息后_摘要与消息随即可读() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        _ = try await live("s1", file: file)
        let indexer = PiHistoryIndexer(agent: .pi, paths: AgentPaths(pi: rig.piPaths), files: store.files) { _ in nil }!
        let consuming = Task { await services.consumePiHistory(indexer.events(following: AsyncStream { $0.yield([file]) }, scope: .all), agent: .pi) }
        defer { consuming.cancel() }
        for try await count in store.observe({ try $0.piMessages(of: "s1").count }) where count == 4 { break }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("u3", "a2", at: .now, user: "第三问") + "\n").utf8))
        try handle.close()

        _ = try await eventually(store, {
            try $0.piMessages(of: "s1").last?.text == "第三问" && $0.allPiSessionStates().first?.pendingPrompt == "第三问"
        }) { $0 }
    }

    /// Mac 重启：启动对账之后会话重新连上，正在处理的提问照样在——不必等文件再追加。
    @Test func 重启后会话重新连上_正在处理的提问仍在() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("u3", "a2", at: .now, user: "第三问") + "\n").utf8))
        try handle.close()
        _ = try await live("s1", file: file)
        await backfill()
        #expect(try await record("s1").pendingPrompt == "第三问")

        try await services.resetPiState()  // 重启时的启动对账
        _ = try await live("s1", file: file)  // 桥重新发现它；文件没有新内容，不会再读

        #expect(try await record("s1").pendingPrompt == "第三问")
    }

    /// 一直开着的 Mac 也按天清理安静了的会话的对话，不只在启动时。
    @Test func 一直开着的Mac每天清理一次对话() async throws {
        let old = try sessionFile("old", at: .now.addingTimeInterval(-30 * 86_400))
        await backfill()
        try await store.writePiTranscript(try PiHistory.index(file: old, agent: .pi, from: nil, files: store.files).transcript)
        #expect(try await store.piMessages(of: "old").count == 4)

        let days = Mutex(0)
        let timing = Timing(now: { Date.now.addingTimeInterval(Double(days.withLock { $0 }) * 86_400) }) { _ in
            days.withLock { $0 += 8 }  // 睡一觉醒来已过了 8 天
            if days.withLock({ $0 }) > 8 { try await Task.sleep(for: .seconds(3_600)) }
        }
        let pruning = Task { await services.historyStore.keepPruned(timing: timing) }
        defer { pruning.cancel() }

        for try await count in store.observe({ try $0.piMessages(of: "old").count }) where count == 0 { break }
    }
}
#endif
