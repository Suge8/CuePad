#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
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
            try await rig.bridge.configure(model: PiModelKey(provider: "openai", id: codexTestModel), thinking: .high, name: "看图", in: id)
            #expect(rig.bridge.session(id: id)?.model?.key.id == codexTestModel)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            await #expect(throws: PiBridgeError.rejected("unknown_model")) {
                try await rig.bridge.configure(model: PiModelKey(provider: "openai", id: "no-such-model"), in: id)
            }

            try await rig.runtime.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let file = try #require(session.sessionFile)
            let resumed = try await rig.runtime.resume(
                IndexedSession(id: session.sessionID, path: file.path, cwd: rig.codex.work.path, lastActivityAt: .now, agent: .codex))
            #expect(rig.bridge.session(id: resumed)?.hosted == true && rig.bridge.session(id: resumed)?.sessionID == session.sessionID)
            _ = try await rig.bridge.send(PiMessage(text: "Reply with the single word AGAIN."), to: resumed)
            try await eventually("接着回答了", timeout: .seconds(120)) { rig.replies(session).last?.contains("AGAIN") == true }
        }
    }

    /// 需要你确认的命令：会话停在"等你确认"、带着要跑的命令；在 CuePad 里允许后命令照常跑完，这一轮做完。
    @Test func aPermissionRequestIsAnsweredFromCuePad() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-2")
            let page = rig.codex.work.appending(path: "page.html")

            _ = try await rig.bridge.send(PiMessage(text: "Run exactly this shell command (it needs network access, request escalation if the sandbox blocks it): curl -s -o page.html https://example.com"), to: id)
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
        }
    }
}
#endif
