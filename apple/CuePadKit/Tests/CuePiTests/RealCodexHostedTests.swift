#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 真 Codex（钉住的版本）+ 假模型：发送、权限、结束后恢复、停止四条流程，外加配置、失败、起名、技能、计划模式提问。
@MainActor
@Suite(RealAgents.taped(.codex), RealAgents.timeLimit(.minutes(4)))
struct RealCodexHostedTests {
    private func open(_ rig: CodexRig, _ token: String) async throws -> PiSession.ID {
        let id = try await rig.runtime.open(in: rig.codex.work, launchToken: token, name: nil, model: nil, thinking: nil)
        let opened = try #require(rig.bridge.session(id: id))
        #expect(opened.hosted && opened.agent == .codex && opened.launchToken == token)
        return id
    }

    // MARK: 发送

    @Test func aMessageWithAnImageReachesTheModelAndTheAnswerLandsInTheTranscript() async throws {
        try await withCodexRig { rig in
            rig.model.on("What color is this image") { .say($0.images.isEmpty ? "I see no image" : "red") }
            let log = ChangeLog(rig.bridge)
            let id = try await open(rig, "token-1")
            let delivery = UUID()
            let image = PiImage(mimeType: "image/png", data: try solidPNG(red: 1, green: 0, blue: 0))
            try await rig.bridge.send(PiMessage(text: "What color is this image? Answer with one lowercase word.", images: [image], deliveryID: delivery.uuidString), to: id)
            // 上下文余量（`thread/tokenUsage/updated`）、歇下（Stop 钩子）与会话文件里的回答走三条通道，先后不定：一起等
            try await eventually("这一轮做完、报了上下文余量、回答落盘") {
                log.states.contains(.thinking) && rig.bridge.session(id: id).map {
                    $0.state == .settled && $0.context?.window ?? 0 > 0 && rig.replies($0).last == "red"
                } == true
            }

            let request = try #require(rig.model.requests.last)
            #expect(request.api == .responses && request.model == codexTestModel && request.images.count == 1, "\(request.path) \(request.model) \(request.images)")
            #expect(rig.draftLanded(id))
            let session = try #require(rig.bridge.session(id: id))
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text.hasPrefix("What color is this image?") && mine.text.contains("![](cuepad://file/"))
        }
    }

    @Test func aHostedSessionIsConfiguredInPlace() async throws {
        try await withCodexRig { rig in
            let id = try await open(rig, "token-config")
            try await eventually("模型清单报上来") { rig.bridge.session(id: id)?.availableModels.isEmpty == false }
            let session = try #require(rig.bridge.session(id: id))
            let other = try #require(session.availableModels.first { $0.key.id != codexTestModel })
            try await rig.bridge.configure(PiConfig(model: other.key), in: id)
            #expect(rig.bridge.session(id: id)?.model?.key == other.key)
            try await rig.bridge.configure(PiConfig(model: PiModelKey(provider: CodexModel.provider, id: codexTestModel), thinking: .high, name: "看图"), in: id)
            #expect(rig.bridge.session(id: id)?.model?.key.id == codexTestModel)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            let unknown = await #expect(throws: PiBridgeError.unknownModel(.codex)) { try await rig.bridge.command("/model no-such-model", in: id) }
            #expect(unknown?.localizedDescription == "Codex 里没有这个模型")

            try await rig.bridge.send(PiMessage(text: "Reply OK."), to: id)
            try await eventually("换到的模型与强度用在了请求里") { rig.model.requests.last?.effort == "high" }
            #expect(rig.model.requests.last?.model == codexTestModel)
        }
    }

    @Test func aFailedTurnLeavesTheSessionInErrorWithTheReason() async throws {
        try await withCodexRig { rig in
            rig.model.on("Reply OK", .fail("bad things happened"))
            let id = try await open(rig, "token-4")

            try await rig.bridge.send(PiMessage(text: "Reply OK."), to: id)
            try await eventually("这一轮失败，带着原因") { rig.bridge.session(id: id)?.detail?.contains("bad things happened") == true }
            let session = try #require(rig.bridge.session(id: id))
            #expect(session.state == .error)
            #expect(session.errorMessage?.contains("bad things happened") == true)
        }
    }

    // MARK: 权限

    /// 两档模型的命令工具不同：gpt-5.5 的函数 `exec_command`，gpt-6-luna 一档的代码模式 `exec`（一段 JS，里面调 `tools.exec_command`）。
    /// CuePad 看到的一样（app-server 报同样的 `commandExecution` 项与审批请求），这里两档都走一遍。
    nonisolated static func escalatedCommand(_ command: String, model: String) -> FakeReply {
        let arguments: [String: any Sendable] = ["cmd": command, "sandbox_permissions": "require_escalated", "justification": "test"]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: arguments)) ?? Data(), as: UTF8.self)
        return model == codexTestModel
            ? .call("exec_command", arguments)
            : .custom("exec", "const r = await tools.exec_command(\(json)); text(JSON.stringify(r));")
    }

    @Test(arguments: [codexTestModel, "gpt-6-luna"], [true, false])
    func aPermissionRequestIsAnsweredFromCuePad(model: String, allow: Bool) async throws {
        try await withCodexRig(approvals: "on-request", model: model) { rig in
            rig.model.on("Make the marker file") { request in
                request.step == 0 ? Self.escalatedCommand("echo allowed > marker.txt", model: model) : .say("FINISHED")
            }
            let id = try await open(rig, "token-2")
            let marker = rig.codex.work.appending(path: "marker.txt")

            try await rig.bridge.send(PiMessage(text: "Make the marker file."), to: id)
            try await eventually("等你确认") { rig.bridge.session(id: id)?.question != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.confirm) && question.text.hasPrefix("允许 Codex 运行命令？") && question.text.contains("marker.txt"))
            #expect(!FileManager.default.fileExists(atPath: marker.path), "没回答前不执行")

            try await rig.bridge.answer(.confirmed(allow), to: try #require(question.promptID), in: id)

            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled && rig.replies(try! #require(rig.bridge.session(id: id))).last == "FINISHED" }
            #expect(FileManager.default.fileExists(atPath: marker.path) == allow)
            let result = try #require(rig.model.requests.last?.results.last)
            #expect(allow ? result.contains("exit_code\":0") || result.contains("Process exited with code 0") : result.lowercased().contains("rejected"), "模型收到的工具结果：\(result)")
        }
    }

    // MARK: 结束后恢复

    @Test func anEndedSessionIsResumedWithItsConversation() async throws {
        try await withCodexRig { rig in
            let id = try await open(rig, "token-resume")
            try await rig.bridge.send(PiMessage(text: "Remember the word PAPAYA."), to: id)
            let session = try #require(rig.bridge.session(id: id))
            try await eventually("第一轮答完") { rig.bridge.session(id: id)?.state == .settled && rig.replies(session).count == 1 }

            try await rig.bridge.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let file = try #require(session.sessionFile)
            let resumed = try await rig.runtime.resume(
                IndexedSession(id: session.sessionID, path: file.path, cwd: rig.codex.work.path, lastActivityAt: .now, agent: .codex))
            #expect(rig.bridge.session(id: resumed)?.hosted == true && rig.bridge.session(id: resumed)?.sessionID == session.sessionID)
            try await rig.bridge.send(PiMessage(text: "Which word?"), to: resumed)
            try await eventually("接着回答了") { rig.replies(session).count == 2 }
            let request = try #require(rig.model.requests.last)
            #expect(request.said.suffix(2) == ["Remember the word PAPAYA.", "Which word?"], "恢复后模型看到先前的对话：\(request.said)")
        }
    }

    // MARK: 停止

    @Test func stoppingATurnLeavesTheSessionReadyForTheNextMessage() async throws {
        try await withCodexRig { rig in
            let gate = rig.model.gate()
            rig.model.on("Take your time", .held(gate, then: .say("TOO LATE")))
            let id = try await open(rig, "token-stop")

            try await rig.bridge.send(PiMessage(text: "Take your time."), to: id)
            try await gate.reached()
            try await rig.bridge.abort(id)
            try await eventually("停下了，在途的请求被断开") { rig.bridge.session(id: id)?.state == .settled && gate.waiting == 0 }

            try await rig.bridge.send(PiMessage(text: "Reply with the single word NEXT."), to: id)
            let session = try #require(rig.bridge.session(id: id))
            try await eventually("下一句照常回答") { rig.replies(session).last?.contains("NEXT") == true }
            #expect(!rig.replies(session).contains("TOO LATE"))
            #expect(try rig.transcript(session).messages.contains { $0.role == .known(.system) && $0.text == PiNotice.stopped.rawValue })
        }
    }

    // MARK: 其他

    @Test func aHostedSessionNamesItselfFromItsFirstMessageInATemporaryThread() async throws {
        try await withCodexRig { rig in
            rig.model.on("single-line task title") { _ in .say(#"{"title":"Fix blank login page"}"#) }
            let id = try await open(rig, "token-name")
            #expect(rig.bridge.canNameItself(id))
            try await rig.bridge.send(PiMessage(text: "Fix the login page that renders blank after sign-in. Reply with OK only."), to: id)
            try await eventually("这一轮做完、第一句话上报") {
                rig.bridge.session(id: id).map { $0.state == .settled && $0.firstMessage != nil && rig.replies($0).last != nil } == true
            }
            let name = try await rig.bridge.suggestName(for: id)
            #expect(name == "Fix blank login page")
            #expect(rig.bridge.session(id: id)?.name == nil, "只起名，不写回")
            #expect(rig.bridge.sessions.map(\.id) == [id], "临时线程不是会话")
            try await rig.bridge.configure(PiConfig(name: name), in: id)
            let thread = try await rig.runtime.control(try #require(rig.runtime.tracked[id])).call("thread/read", ["threadId": .string(try #require(rig.bridge.session(id: id)).sessionID)])
            #expect(thread["thread"]?["name"]?.string == name, "写进了 Codex")
        }
    }

    @Test func aSkillLineIsSpokenWithItsDelivery() async throws {
        try await withCodexRig { rig in
            let skill = rig.codex.home.appending(path: "skills/kiwi-echo", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: kiwi-echo\ndescription: Echo the user's word with a fixed tag\n---\nReply with exactly KIWI-7 followed by a space and the user's word in uppercase, nothing else.\n"
                .write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            let id = try await open(rig, "token-skill")
            try await eventually("命令清单里有这个技能") { rig.bridge.session(id: id)?.commands.contains { $0.name == "skill:kiwi-echo" } == true }

            let delivery = UUID()
            try await rig.bridge.send(PiMessage(text: "/skill:kiwi-echo banana", deliveryID: delivery.uuidString), to: id)
            let session = try #require(rig.bridge.session(id: id))
            try await eventually("模型收到了技能的内容") { rig.model.requests.last?.messages.contains { $0.text.contains("Reply with exactly KIWI-7") } == true }
            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled && !rig.replies(session).isEmpty }
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text == "/skill:kiwi-echo banana")
        }
    }

    @Test func aPlanModeQuestionIsAnsweredFromCuePad() async throws {
        try await withCodexRig { rig in
            rig.model.on("Ask me which drink") { request in
                request.step == 0
                    ? .call("request_user_input", ["questions": [[
                        "id": "drink", "header": "Drink", "question": "Tea or Coffee?",
                        "options": [["label": "Tea", "description": "hot leaves"], ["label": "Coffee", "description": "hot beans"]],
                    ] as [String: any Sendable]]])
                    : .say("You chose: \(request.results.last ?? "")")
            }
            let id = try await open(rig, "token-ask")
            try await eventually("命令清单里有 /plan") { rig.bridge.session(id: id)?.commands.contains { $0.name == "plan" } == true }

            try await rig.bridge.command("/plan Ask me which drink I want, Tea or Coffee.", in: id)
            try await eventually("等你回答") { rig.bridge.session(id: id)?.question?.promptID != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.select) && question.allowsOther)
            let coffee = try #require(question.options.first { $0.lowercased().contains("coffee") })

            try await rig.bridge.answer(.option(coffee), to: try #require(question.promptID), in: id)

            try await eventually("拿到答案接着说，说完落盘") {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last?.contains("Coffee") == true } == true
            }
            #expect(rig.bridge.session(id: id)?.question == nil)
            try await rig.bridge.command("/default", in: id)
        }
    }

    // MARK: 子代理（gpt-6-luna 一档的 `collaboration` 工具：spawn_agent、wait_agent）

    @Test func aSubagentShowsUpInTheRoster() async throws {
        try await withCodexRig(model: "gpt-6-luna") { rig in
            rig.model.on("Spawn one subagent called pong") { request in
                switch request.step {
                case 0: .call("spawn_agent", ["task_name": "pong", "message": "Child task: pong. Reply with PONG.", "fork_turns": "none"])
                case 1: .call("wait_agent", ["timeout_ms": 30000])
                default: .say("The subagent said PONG")
                }
            }
            rig.model.on("Child task: pong") { _ in .say("PONG") }
            let id = try await open(rig, "token-3")
            let log = ChangeLog(rig.bridge)

            try await rig.bridge.send(PiMessage(text: "Spawn one subagent called pong and tell me what it said."), to: id)

            // 变化日志经异步流收下，比桥上的会话晚一拍：等它也收到这次变化
            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled && log.states.contains(.thinking) && log.states.last == .settled }
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
            let indexed = history.events.compactMap { if case .backfillFinished(let files?) = $0 { files } else { nil } }.first
            #expect(indexed?.map(\.lastPathComponent).allSatisfy { $0.contains(main) } == true && indexed?.count == 1)
        }
    }

    /// 子代理的请求停在闸门上，代替原来让它 sleep：主会话先答 DISPATCHED 歇在“等子代理”，放行后读回结果才歇下。
    @Test func aSubagentLeftRunningIsReadBackBeforeSettling() async throws {
        try await withCodexRig(model: "gpt-6-luna") { rig in
            let gate = rig.model.gate()
            rig.model.on("Spawn one subagent called fruit") { request in
                request.step == 0
                    ? .call("spawn_agent", ["task_name": "fruit", "message": "Child task: fruit. Reply with BANANA.", "fork_turns": "none"])
                    : .say("DISPATCHED")
            }
            rig.model.on({ $0.said.contains { $0.contains("Spawn one subagent called fruit") } && $0.messages.contains { $0.text.contains("BANANA") } }) { _ in .say("BANANA") }
            rig.model.on("Child task: fruit", .held(gate, then: .say("BANANA")))
            let id = try await open(rig, "token-wake")
            let log = ChangeLog(rig.bridge)

            try await rig.bridge.send(PiMessage(text: "Spawn one subagent called fruit and do not wait for it."), to: id)

            try await gate.reached()
            // 变化日志经异步流收下，比桥上的会话晚一拍：等它也收到这次变化
            try await eventually("这一轮结束、在等子代理") { rig.bridge.session(id: id)?.state == .delegating && log.states.last == .delegating }
            #expect(log.settles == 0)
            let delegating = try #require(rig.bridge.session(id: id))
            let dispatched = try #require(try rig.transcript(delegating).recap.answeredAt)

            gate.open()
            try await eventually("读到结果后歇下") {
                rig.bridge.session(id: id).map { $0.state == .settled && rig.replies($0).last == "BANANA" } == true && log.states.last == .settled
            }
            #expect(log.settles == 1, "\(log.states)")
            // 歇下就绪（`PiSessionState.answered`）：派活那一轮的收尾早于补的那一轮的开始（CuePad 发出空输入的时刻），那一轮的收尾不早于它
            let settled = try #require(rig.bridge.session(id: id))
            let turn = try #require(settled.turnStartedAt), answered = try #require(try rig.transcript(settled).recap.answeredAt)
            #expect(dispatched < turn && turn <= answered, "\(dispatched) \(turn) \(answered)")
            let roster = try #require(rig.bridge.session(id: id)?.subagents)
            #expect(roster.map(\.name) == ["fruit"] && roster.first?.phase == .known(.done))
        }
    }
}
#endif
