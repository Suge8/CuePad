#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 Codex（`codex app-server`，真模型，账号里最便宜的），状态来自真钩子，对话来自真会话文件。
@MainActor
@Suite(RealAgents.taped(.codex), .agentTape(.codex), RealAgents.timeLimit(.minutes(4)), RealAgents.serialWhenRecording(.codex))
struct RealCodexHostedTests {
    /// 开一个新会话、发一句带图的话：会话出现在桥上（后台托管、带着认领标识），做完一轮后歇下；会话文件里你的话带着这次投送的 id 与图片，
    /// 回答是一条 Codex 消息；换模型、强度与改名生效。结束后下线；再接着这个已结束的会话说，它在后台恢复、接着回答。
    @Test func aHostedSessionTakesAMessageWithAnImageIsConfiguredEndedAndResumed() async throws {
        try await withCodexRig { rig in
            let log = ChangeLog(rig.bridge)
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)

            let opened = try #require(rig.bridge.session(id: id))
            #expect(opened.hosted && opened.agent == .codex && opened.launchToken == "token-1")
            let delivery = UUID()
            let image = PiImage(mimeType: "image/png", data: try solidPNG(red: 1, green: 0, blue: 0))
            let message = PiMessage(text: "What color is this image? Answer with one lowercase word.", images: [image], deliveryID: delivery.uuidString)
            #expect(try await rig.bridge.send(message, to: id) == .immediate)
            // 上下文余量（`thread/tokenUsage/updated`）、歇下（Stop 钩子）与会话文件里的回答走三条通道，先后不定：一起等
            try await eventually("这一轮做完、报了上下文余量、回答落盘", timeout: .seconds(120)) {
                log.states.contains(.thinking) && rig.bridge.session(id: id).map {
                    $0.state == .settled && $0.context?.window ?? 0 > 0 && rig.replies($0).last?.lowercased().contains("red") == true
                } == true
            }

            #expect(rig.draftLanded(id))
            let session = try #require(rig.bridge.session(id: id))
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text.hasPrefix("What color is this image?") && mine.text.contains("![](cuepad://img/"))
            #expect(rig.replies(session).last?.lowercased().contains("red") == true, "\(rig.replies(session))")

            let other = try #require(session.availableModels.first { $0.key.id != codexTestModel })
            try await rig.bridge.configure(model: other.key, in: id)
            #expect(rig.bridge.session(id: id)?.model?.key == other.key)
            try await rig.bridge.configure(model: PiModelKey(provider: CodexModel.provider, id: codexTestModel), thinking: .high, name: "看图", in: id)
            #expect(rig.bridge.session(id: id)?.model?.key.id == codexTestModel)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            // 斜杠命令换到没有的模型：提示点的是这个会话的 Agent
            let unknown = await #expect(throws: PiBridgeError.unknownModel(.codex)) { try await rig.bridge.command("/model no-such-model", in: id) }
            #expect(unknown?.localizedDescription == "这台 Mac 上的 Codex 里找不到这个模型")

            try await rig.bridge.end(id)
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

    /// CuePad 起的 `codex` 是外壳（npm 装的就是 node 外壳）、真 codex 是它的子进程：钩子仍认回这个托管会话，不另接一个；
    /// 忙闲来自托管进程自己的通知，第一句照常进入思考、答完歇下。
    @Test func aWrappedCodexAnswersTheFirstMessage() async throws {
        try await withCodexRig(wrapped: true) { rig in
            let log = ChangeLog(rig.bridge)
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-wrapped", name: nil, model: nil, thinking: nil)
            let threadID = try #require(rig.bridge.session(id: id)?.sessionID)

            _ = try await rig.bridge.send(PiMessage(text: "Reply with the single word WRAPPED."), to: id)
            try await eventually("这一轮做完、回答落盘", timeout: .seconds(120)) {
                log.states.contains(.thinking)
                    && rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last?.uppercased().contains("WRAPPED") == true } == true
            }
            #expect(rig.bridge.sessions.filter { $0.sessionID == threadID }.map(\.id) == [id])
            #expect(rig.draftLanded(id))
        }
    }

    /// 需要你确认的命令：会话停在"等你确认"、带着要跑的命令；在 CuePad 里允许后命令照常跑完，这一轮做完。
    @Test func aPermissionRequestIsAnsweredFromCuePad() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-2", name: nil, model: nil, thinking: nil)
            let page = rig.codex.work.appending(path: "page.html")

            _ = try await rig.bridge.send(PiMessage(text: "Run exactly this shell command, requesting escalated sandbox permissions up front because it needs network access: curl -s -o page.html https://example.com"), to: id)
            try await eventually("等你确认", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.confirm) && question.text.hasPrefix("允许 Codex 运行命令？") && question.text.contains("curl"))

            try await rig.bridge.answer(.confirmed(true), to: try #require(question.promptID), in: id)

            try await eventually("这一轮做完", timeout: .seconds(120)) { rig.bridge.session(id: id)?.state == .settled }
            #expect(FileManager.default.fileExists(atPath: page.path))
        }
    }

    /// Plan 模式里不挡着这一轮的提问（`request_user_input_async`，Codex 问完睡着等）：在 CuePad 里用 /plan 进 Plan 模式说话，
    /// 会话停在"等你回答"、带着问题与选项（也能自己填），睡着等的那段不显示成在调工具；在 CuePad 里选了，答案当你的下一句话交给它，
    /// 它接着说。说完的回答落了库，正在说的话随之换下。
    @Test func aPlanModeQuestionIsAnsweredFromCuePad() async throws {
        try await withCodexRig { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-ask", name: nil, model: nil, thinking: nil)
            try await eventually("命令清单里有 /plan") { rig.bridge.session(id: id)?.commands.contains { $0.name == "plan" } == true }
            let log = ChangeLog(rig.bridge)

            try await rig.bridge.command("/plan Ask me which drink I want, Tea or Coffee, with the request_user_input tool, and sleep while you wait for my answer instead of ending your turn. Then reply with only the option I chose.", in: id)
            try await eventually("等你回答", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question?.promptID != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.select) && question.allowsOther)
            let coffee = try #require(question.options.first { $0.lowercased().contains("coffee") })

            try await rig.bridge.answer(.option(coffee), to: try #require(question.promptID), in: id)

            try await eventually("拿到答案接着说，说完落盘", timeout: .seconds(120)) {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last?.lowercased().contains("coffee") == true } == true
            }
            #expect(rig.bridge.session(id: id)?.question == nil)
            #expect(rig.draftLanded(id))
            #expect(!log.details.contains { $0?.contains("clocksleep") == true }, "\(log.details)")
            try await rig.bridge.command("/default", in: id)
        }
    }

    /// 子代理：派出去时出现在会话的子代理名册里（名字是派它时给的任务名），交回结果后落定；在这一轮里等到了它，这一轮做完只歇下一次。
    @Test func aSubagentShowsUpInTheRoster() async throws {
        try await withCodexRig { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-3", name: nil, model: nil, thinking: nil)
            let log = ChangeLog(rig.bridge)

            _ = try await rig.bridge.send(PiMessage(text: "Spawn exactly one subagent with task name pong and ask it to reply with the word PONG. Wait for it, then tell me what it said."), to: id)

            try await eventually("这一轮做完", timeout: .seconds(180)) { rig.bridge.session(id: id)?.state == .settled && log.states.contains(.thinking) }
            #expect(log.settles == 1, "\(log.states)")
            let roster = try #require(rig.bridge.session(id: id)?.subagents)
            #expect(roster.map(\.name) == ["pong"])
            #expect(roster.first?.phase == .known(.done) && roster.first?.settledAt != nil)
            #expect(roster.first?.action.contains("PONG") == true)

            // 子代理自己的会话文件与主会话同层，会话索引里只有主会话
            let main = try #require(rig.bridge.session(id: id)?.sessionID)
            let files = try #require(FileManager.default.enumerator(at: rig.codex.home.appending(path: "sessions"), includingPropertiesForKeys: nil))
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
            #expect(files.count == 2)
            let history = HistoryEventLog(PiHistoryIndexer(agent: .codex, paths: rig.codex.paths, files: scratchFiles) { _ in nil }!)
            try await eventually("回填完") { history.finishedBackfill }
            // 主会话文件在这一轮歇下后可能还在写，会多一次更新：只看更新了哪些会话
            #expect(Set(history.updates.map(\.checkpoint.sessionID)) == [main])
            let indexed = history.events.compactMap { if case .backfillFinished(let files) = $0 { files } else { nil } }.first
            #expect(indexed?.map(\.lastPathComponent).allSatisfy { $0.contains(main) } == true && indexed?.count == 1)
        }
    }

    /// 派完不等的子代理：这一轮结束时它还在跑，会话在等子代理、不歇下；它做完后 CuePad 补一轮让会话读到结果，
    /// 那一轮答出结果后才歇下，只歇下一次。
    @Test func aSubagentLeftRunningIsReadBackBeforeSettling() async throws {
        try await withCodexRig { rig in
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-wake", name: nil, model: nil, thinking: nil)
            let log = ChangeLog(rig.bridge)

            _ = try await rig.bridge.send(PiMessage(text: "Spawn exactly one subagent with task name fruit. Tell it: sleep 15 seconds with the sleep tool, then reply with exactly the word BANANA. Do not wait for it: end your turn right away, replying only DISPATCHED. When its result reaches you later, reply with exactly the word it sent you."), to: id)

            try await eventually("这一轮结束、在等子代理", timeout: .seconds(120)) { rig.bridge.session(id: id)?.state == .delegating }
            #expect(log.settles == 0)
            try await eventually("读到结果后歇下", timeout: .seconds(180)) {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last?.uppercased().contains("BANANA") == true } == true
            }
            #expect(log.settles == 1, "\(log.states)")
            let roster = try #require(rig.bridge.session(id: id)?.subagents)
            #expect(roster.map(\.name) == ["fruit"] && roster.first?.phase == .known(.done))
        }
    }

    /// 提供方拒绝了这一轮（本机假服务对每个请求回 400，不花钱）：Codex 不重试、这一轮失败，没有 Stop 钩子；
    /// 会话停在出错，说明是提供方的原话，悬停看的全文也在。
    @Test func aFailedTurnLeavesTheSessionInErrorWithTheReason() async throws {
        let provider = try await RejectingProvider()
        defer { provider.stop() }
        try await withCodexRig { rig in
            try rig.codex.use(provider)
            let id = try await rig.runtime.open(in: rig.codex.work, launchToken: "token-4", name: nil, model: nil, thinking: nil)

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

#endif
