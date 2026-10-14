#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Network
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 Codex（`codex app-server`，真模型，账号里最便宜的），状态来自真钩子，对话来自真会话文件。
@MainActor
@Suite(.enabled(if: realCodexSignedIn, "需要本机装有并登录了 codex"), .timeLimit(.minutes(4)), .serialized)
struct RealCodexHostedTests {
    /// 开一个新会话、发一句带图的话：会话出现在桥上（后台托管、带着认领标识），做完一轮后歇下；会话文件里你的话带着这次投送的 id 与图片，
    /// 回答是一条 Codex 消息；换模型、强度与改名生效。结束后下线；再接着这个已结束的会话说，它在后台恢复、接着回答。
    @Test func aHostedSessionTakesAMessageWithAnImageIsConfiguredEndedAndResumed() async throws {
        try await withCodexRig { rig in
            let log = ChangeLog(rig.bridge)
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-1")

            let opened = try #require(rig.bridge.session(id: id))
            #expect(opened.hosted && opened.agent == .codex && opened.launchToken == "token-1")
            let delivery = UUID()
            let image = PiImage(mimeType: "image/png", data: try solidPNG(red: 1, green: 0, blue: 0))
            let message = PiMessage(text: "What color is this image? Answer with one lowercase word.", images: [image], deliveryID: delivery.uuidString)
            #expect(try await rig.bridge.send(message, to: id) == .immediate)
            try await eventually("这一轮做完", timeout: .seconds(120)) { log.states.contains(.thinking) && rig.bridge.session(id: id)?.state == .settled }

            let session = try #require(rig.bridge.session(id: id))
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text.hasPrefix("What color is this image?") && mine.text.contains("![](cuepad://img/"))
            #expect(rig.replies(session).last?.lowercased().contains("red") == true, "\(rig.replies(session))")
            #expect(session.context?.window ?? 0 > 0)

            let other = try #require(session.availableModels.first { $0.key.id != codexTestModel })
            try await rig.bridge.configure(model: other.key, in: id)
            #expect(rig.bridge.session(id: id)?.model?.key == other.key)
            try await rig.bridge.configure(model: PiModelKey(provider: CodexModel.provider, id: codexTestModel), thinking: .high, name: "看图", in: id)
            #expect(rig.bridge.session(id: id)?.model?.key.id == codexTestModel)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            await #expect(throws: PiBridgeError.rejected("unknown_model")) {
                try await rig.bridge.configure(model: PiModelKey(provider: CodexModel.provider, id: "no-such-model"), in: id)
            }

            try await rig.runtime.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let file = try #require(session.sessionFile)
            let resumed = try await rig.runtime.resume(
                IndexedSession(id: session.sessionID, path: file.path, cwd: rig.codex.work.path, lastActivityAt: .now, agent: .codex))
            #expect(rig.bridge.session(id: resumed)?.hosted == true && rig.bridge.session(id: resumed)?.sessionID == session.sessionID)
            _ = try await rig.bridge.send(PiMessage(text: "Reply with the single word AGAIN."), to: resumed)
            // 前一句要它答小写，模型可能沿用：大小写不论
            try await eventually("接着回答了", timeout: .seconds(120)) { rig.replies(session).last?.uppercased().contains("AGAIN") == true }
        }
    }

    /// 需要你确认的命令：会话停在"等你确认"、带着要跑的命令；在 CuePad 里允许后命令照常跑完，这一轮做完。
    @Test func aPermissionRequestIsAnsweredFromCuePad() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-2")
            let page = rig.codex.work.appending(path: "page.html")

            _ = try await rig.bridge.send(PiMessage(text: "Run exactly this shell command, requesting escalated sandbox permissions up front because it needs network access: curl -s -o page.html https://example.com"), to: id)
            try await eventually("等你确认", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.confirm) && question.text.contains("curl"))

            try await rig.bridge.answer(.confirmed(true), to: try #require(question.promptID), in: id)

            try await eventually("这一轮做完", timeout: .seconds(120)) { rig.bridge.session(id: id)?.state == .settled }
            #expect(FileManager.default.fileExists(atPath: page.path))
        }
    }

    /// 子代理：派出去时出现在会话的子代理名册里（名字是派它时给的任务名），交回结果后落定。
    @Test func aSubagentShowsUpInTheRoster() async throws {
        try await withCodexRig { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-3")
            let log = ChangeLog(rig.bridge)

            _ = try await rig.bridge.send(PiMessage(text: "Spawn exactly one subagent with task name pong and ask it to reply with the word PONG. Wait for it, then tell me what it said."), to: id)

            try await eventually("这一轮做完", timeout: .seconds(180)) { rig.bridge.session(id: id)?.state == .settled && log.states.contains(.thinking) }
            let roster = try #require(rig.bridge.session(id: id)?.subagents)
            #expect(roster.map(\.name) == ["pong"])
            #expect(roster.first?.phase == .known(.done) && roster.first?.settledAt != nil)
            #expect(roster.first?.action.contains("PONG") == true)

            // 子代理自己的会话文件与主会话同层，会话索引里只有主会话
            let main = try #require(rig.bridge.session(id: id)?.sessionID)
            let files = try #require(FileManager.default.enumerator(at: rig.codex.home.appending(path: "sessions"), includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            #expect(files.count == 2)
            let history = HistoryEventLog(PiHistoryIndexer(root: rig.codex.home.appending(path: "sessions"), agent: .codex, files: scratchFiles) { _ in nil })
            try await eventually("回填完") { history.finishedBackfill }
            #expect(history.updates.map(\.checkpoint.sessionID) == [main])
            let indexed = history.events.compactMap { if case .backfillFinished(let files) = $0 { files } else { nil } }.first
            #expect(indexed?.map(\.lastPathComponent).allSatisfy { $0.contains(main) } == true && indexed?.count == 1)
        }
    }

    /// 提供方拒绝了这一轮（本机假服务对每个请求回 400，不花钱）：Codex 不重试、这一轮失败，没有 Stop 钩子；
    /// 会话停在出错，说明是提供方的原话，悬停看的全文也在。
    @Test func aFailedTurnLeavesTheSessionInErrorWithTheReason() async throws {
        let provider = try await RejectingProvider()
        defer { provider.stop() }
        try await withCodexRig { rig in
            let config = rig.codex.home.appending(path: "config.toml")
            let text = try String(contentsOf: config, encoding: .utf8)
            try ("model_provider = \"rejecting\"\n" + text + """

                [model_providers.rejecting]
                name = "rejecting"
                base_url = "http://127.0.0.1:\(provider.port)/v1"
                wire_api = "responses"

                """).write(to: config, atomically: true, encoding: .utf8)
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-4")

            _ = try await rig.bridge.send(PiMessage(text: "Reply OK."), to: id)
            try await eventually("这一轮失败，带着原因", timeout: .seconds(120)) {
                rig.bridge.session(id: id)?.detail?.contains(RejectingProvider.reason) == true
            }
            let session = try #require(rig.bridge.session(id: id))
            #expect(session.state == .error)
            #expect(session.errorMessage?.contains(RejectingProvider.reason) == true)
        }
    }
}

/// 本机的假模型提供方：每个请求都回 400 和一句固定的原因。
private final class RejectingProvider: Sendable {
    static let reason = "bad things happened"
    private let listener: NWListener
    let port: UInt16

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            // 请求读一块就够了：不论问什么都拒绝
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, _, _ in
                let body = #"{"error":{"message":"\#(Self.reason)","type":"invalid_request_error","code":"bad"}}"#
                let reply = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        var iterator = ready.stream.makeAsyncIterator()
        port = try #require(await iterator.next())
    }

    func stop() { listener.cancel() }
}
#endif
