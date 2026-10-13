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

    /// 一个会话文件：两轮问答，时间在 `at`。
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

    /// 像索引器那样读：最近 7 天修改过的文件要对话，更早的只读摘要。
    private func consume(_ files: [URL]) async {
        let events = AsyncStream<PiHistoryEvent> { continuation in
            for file in files {
                let modified = try! file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
                let recent = modified > .now.addingTimeInterval(-PiHistoryPersistence.transcriptWindow)
                continuation.yield(.updated(try! PiHistory.index(file: file, from: nil, transcript: recent, files: store.files)))
            }
            continuation.yield(.backfillFinished(sessionFiles: files))
            continuation.finish()
        }
        await services.consumePiHistory(events)
    }

    /// 桥上看到这个会话在线（状态记录器写出未结束的记录；不结束）。
    private func live(_ sessionID: String, file: URL) async throws -> CuePi.PiSession {
        let session = CuePi.PiSession(
            id: "\(sessionID).100", sessionID: sessionID, agent: .pi, sessionFile: file, pid: 100, cwd: URL(filePath: "/work/x", directoryHint: .isDirectory),
            terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version, state: .thinking, stateSince: .now)
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
        let recent = try sessionFile("recent", at: .now.addingTimeInterval(-3_600))
        let old = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))

        await consume([recent, old])

        let messages = try await store.piMessages(of: "recent")
        #expect(messages.map(\.text) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(messages.map(\.role) == [.known(.user), .known(.pi), .known(.user), .known(.pi)])
        #expect(try await store.piMessages(of: "old").isEmpty)
        for sessionID in ["recent", "old"] {
            let state = try await record(sessionID)
            #expect(state.lastPrompt == "第二问" && state.lastReply == "第二答" && state.pendingPrompt == nil)
        }
        let lastPi = try #require(messages.last { $0.role == .known(.pi) })
        let lastUser = try #require(messages.last { $0.role == .known(.user) })
        #expect(try await record("recent").lastReply == lastPi.text)
        #expect(try await record("recent").lastPrompt == lastUser.text)
    }

    @Test func 七天外的会话按需补写_手机打开时发的请求由这台Mac从会话文件写出对话() async throws {
        let old = try sessionFile("old", at: .now.addingTimeInterval(-10 * 86_400))
        await consume([old])
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
        #expect(try await store.sendRecords().isEmpty)
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

        await consume([file])

        let reply = try #require(try await store.piMessages(of: "old").first { $0.role == .known(.pi) })
        #expect(reply.tools?.commands == 1 && reply.tools?.total == reply.tools?.items.count)
    }

    /// 摘要只有对话这一个写者：Pi 桥上的状态变化不改它；会话结束后没有进行中的提问。
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
        await consume([file])
        #expect(try await record("s1").pendingPrompt == "做到一半")

        try await services.consumePiChanges(AsyncStream { continuation in
            continuation.yield(.stateChanged(session, from: .settled))
            continuation.yield(.ended(session, reason: .closed(reason: "quit")))
            continuation.finish()
        })
        #expect(try await record("s1").pendingPrompt == nil)

        await consume([file])  // 文件再读一遍：已结束的会话不会重新有进行中的提问
        let ended = try await record("s1")
        #expect(ended.pendingPrompt == nil && ended.state == .known(.ended))
    }

    /// 文件一追加就写：Mac 本机界面也读同步记录，这里的延迟就是 Mac 上看到的延迟。
    @Test func 文件追加一条用户消息后_摘要与消息在1秒内可读() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        _ = try await live("s1", file: file)
        let indexer = PiHistoryIndexer(root: rig.piPaths.sessionsDirectory, files: store.files) { _ in nil }
        let consuming = Task { await services.consumePiHistory(indexer.events()) }
        defer { consuming.cancel() }
        for try await count in store.observe({ try $0.piMessages(of: "s1").count }) where count == 4 { break }

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let appended = ContinuousClock.now
        try handle.write(contentsOf: Data((line("u3", "a2", at: .now, user: "第三问") + "\n").utf8))
        try handle.close()

        let deadline = Task { try await Task.sleep(for: .seconds(1)) }
        let watch = Task {
            for try await readable in store.observe({
                try $0.piMessages(of: "s1").last?.text == "第三问" && $0.allPiSessionStates().first?.pendingPrompt == "第三问"
            }) where readable { return true }
            return false
        }
        Task { try? await deadline.value; watch.cancel() }
        let seen = (try? await watch.value) ?? false
        deadline.cancel()
        #expect(seen, "追加后 \(ContinuousClock.now - appended) 仍没读到")
    }

    /// Mac 重启：启动时把上次遗留的记录标为已结束，会话重新连上后，正在处理的提问照样在——不必等文件再追加。
    @Test func 重启后会话重新连上_正在处理的提问仍在() async throws {
        let file = try sessionFile("s1", at: .now.addingTimeInterval(-60))
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line("u3", "a2", at: .now, user: "第三问") + "\n").utf8))
        try handle.close()
        _ = try await live("s1", file: file)
        await consume([file])
        #expect(try await record("s1").pendingPrompt == "第三问")

        try await services.resetPiState()  // 重启：上次的会话都标为已结束
        #expect(try await record("s1").pendingPrompt == nil)
        _ = try await live("s1", file: file)  // 桥重新发现它；文件没有新内容，不会再读

        #expect(try await record("s1").pendingPrompt == "第三问")
    }

    /// 一直开着的 Mac 也按天清理安静了的会话的对话，不只在启动时。
    @Test func 一直开着的Mac每天清理一次对话() async throws {
        let old = try sessionFile("old", at: .now.addingTimeInterval(-30 * 86_400))
        await consume([old])
        try await store.writePiTranscript(try PiHistory.index(file: old, from: nil, files: store.files).transcript)
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

    /// 写不写对话只看读文件时的判定（索引器按文件修改时间）：最近改过的文件即使里面的时间都旧也写全部消息；
    /// 只读了摘要的文件即使里面的时间很近也不写消息——持久化不另按内容时间再判一次。
    @Test func 写不写对话按读文件时的判定_不按文件内容里的时间() async throws {
        let oldInside = try sessionFile("old-inside", at: .now.addingTimeInterval(-30 * 86_400))
        let recentInside = try sessionFile("recent-inside", at: .now.addingTimeInterval(-3_600))
        await services.consumePiHistory(AsyncStream { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: oldInside, from: nil, transcript: true, files: store.files)))
            continuation.yield(.updated(try! PiHistory.index(file: recentInside, from: nil, transcript: false, files: store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [oldInside, recentInside]))
            continuation.finish()
        })

        #expect(try await store.piMessages(of: "old-inside").count == 4)
        #expect(try await store.piMessages(of: "recent-inside").isEmpty)
        #expect(try await record("recent-inside").lastReply == "第二答")
    }
}
#endif
