#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealOpenCodeTests {
    @Test func reconnectingKeepsTheFirstMessageAndOnlyTheServiceCuePadStartedIsStopped() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            try await sandbox.run(["service", "start"])
            _ = await ChildProcess.run(
                OpenCodeSandbox.pinned.executable, ["run", "-m", "\(openCodeTestModel.provider)/no-such-model-xyz", "say hi"], directory: sandbox.work, environment: sandbox.environment,
                timeout: .seconds(120))
            try await eventually("终端的会话出现、名字是首条消息") { session(bridge)?.displayName.contains("say hi") == true }
            let terminalService = try #require(sandbox.service)

            await runtime.stop()()
            #expect(sandbox.service?.pid == terminalService.pid && kill(terminalService.pid, 0) == 0, "终端拉起的服务不动")
            // 第二次重开时会话索引已是最新、不再读对话：首条消息只能从读到哪了里取
            for _ in 0..<2 {
                let reconnected = sandbox.runtime(bridge, store)
                try reconnected.start()
                try await eventually("重新接上") { session(bridge) != nil }
                await quietPeriod(.seconds(2))  // 名字被改写没有事件可等
                #expect(session(bridge)?.displayName.contains("say hi") == true, "名字仍是首条消息：\(String(describing: session(bridge)?.displayName))")
                await reconnected.stop()()
            }

            try await sandbox.run(["service", "stop"])
            try await eventually("服务停了") { kill(terminalService.pid, 0) != 0 }
            let host = sandbox.runtime(bridge, store)
            try host.start()
            _ = try await host.open(in: sandbox.work, launchToken: "t-service", name: nil, model: nil, thinking: nil)
            let started = try #require(sandbox.service)
            await host.stop()()
            try await eventually("CuePad 拉起的服务停掉了") { kill(started.pid, 0) != 0 && sandbox.service == nil }
        }
    }

    @Test func aSessionWhoseModelCannotBeSetIsNotLeftInTheService() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            await #expect(throws: BridgeError.unknownModel(.opencode)) {
                _ = try await runtime.open(
                    in: sandbox.work, launchToken: "token-bad", name: "配不上", model: ModelKey(provider: openCodeTestModel.provider, id: "no-such-model"), thinking: nil)
            }
            #expect(session(bridge) == nil)
            let listed = try await sandbox.api("GET", "/api/session")["data"] as? [Any]
            #expect(listed?.isEmpty == true, "服务里还留着：\(String(describing: listed))")
            #expect(try await store.piSessions().isEmpty)
        }
    }

    @Test func cuePadStartsTheServiceAndHostsSessionsFromOpenToResume() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            #expect(sandbox.service == nil)

            let id = try await runtime.open(in: sandbox.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)

            let opened = try #require(bridge.session(id: id))
            #expect(opened.agent == .opencode && opened.hosted && opened.launchToken == "token-1" && sandbox.service != nil)
            let image = pngData(width: 8, height: 8, shade: 0.9)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word SEEN.", images: [MessageImage(mimeType: "image/png", data: image)]), to: id)
            let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined() + ".png"
            try await eventually("带图的那句与回答进了对话") {
                let messages = try await store.piMessages(of: opened.sessionID)
                return messages.contains { $0.role == .known(.user) && $0.text.contains("cuepad://file/\(hash)") }
                    && messages.last?.role == .known(.pi)
            }
            #expect(store.files.fileURL(for: hash) != nil)
            #expect(sandbox.model.requests.contains { $0.prompt.contains("SEEN") && $0.images.count == 1 }, "假模型没收到图")

            sandbox.model.on("Explore the folder", .call("subagent", ["agent": "explore", "description": "find-readme", "prompt": "list the files in the current directory."]), .say("DONE"))
            try await bridge.send(SessionMessage(text: "Explore the folder"), to: id)
            try await eventually("子代理出现、做完") {
                session(bridge)?.subagents.contains { $0.name == "find-readme" && $0.role == "explore" && $0.phase == .known(.done) } == true
            }
            try await eventually("这一轮做完") { session(bridge)?.state == .settled }

            // 选择题：选一个，再换一次自己填一个不在选项里的答案（OpenCode 的选择题本身允许自己填）
            for (ask, options, answer, expected) in [("Ask the color", ["Red", "Blue"], AnswerValue.option("Blue"), "Blue"), ("Ask the color again", ["Red", "Blue"], .text("Green"), "Green")] {
                let questions: [[String: any Sendable]] = [["header": "Color", "question": "Which color?", "options": options.map { ["label": $0, "description": $0] }]]
                sandbox.model.on(ask) { request in
                    request.step == 0 ? .call("question", ["questions": questions]) : .say(request.results.last?.firstMatch(of: /="([^"]*)"/).map { String($0.1) } ?? "NO ANSWER")
                }
                try await bridge.send(SessionMessage(text: ask), to: id)
                try await eventually("在等你回答") { session(bridge)?.question?.kind == .known(.select) }
                let question = try #require(session(bridge)?.question)
                #expect(question.options == options && question.allowsOther)
                try await bridge.answer(answer, to: question.promptID!, in: id)
                try await eventually("按你的回答接着做完") {
                    let reply = try await replies(store, opened.sessionID).last
                    return session(bridge)?.state == .settled && reply == expected
                }
            }

            try await bridge.end(id)
            #expect(bridge.session(id: id) == nil)
            let indexed = try #require(try await store.piSession(opened.sessionID))
            #expect(indexed.agent == .opencode)

            let resumed = try await runtime.resume(indexed)
            #expect(bridge.session(id: resumed)?.sessionID == opened.sessionID)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word BACK."), to: resumed)
            try await eventually("接着说的回答到了") { try await replies(store, opened.sessionID).last?.contains("BACK") == true }

            try await sandbox.api("DELETE", "/api/session/\(opened.sessionID)")
            try await eventually("删掉的会话下线、索引也删了") {
                let indexed = try await store.piSession(opened.sessionID)
                return bridge.session(id: resumed) == nil && indexed == nil
            }
        }
    }

    /// 恢复：说过话的托管会话结束、接入与后台服务都停了，重新接入后接着它说，模型收到的对话里带着之前说过的。
    @Test(.tags(.smoke)) func aSessionEndedAndItsServiceStoppedResumesWithItsConversation() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let id = try await runtime.open(in: sandbox.work, launchToken: "token-r", name: nil, model: nil, thinking: nil)
            let sessionID = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word FIRST."), to: id)
            try await eventually("第一句答完") { try await replies(store, sessionID).last?.contains("FIRST") == true && session(bridge)?.state == .settled }

            try await bridge.end(id)
            let service = try #require(sandbox.service)
            await runtime.stop()()
            try await eventually("CuePad 拉起的服务随接入停了") { kill(service.pid, 0) != 0 && sandbox.service == nil }
            let indexed = try #require(try await store.piSession(sessionID))

            let restarted = sandbox.runtime(bridge, store)
            try restarted.start()
            let resumed = try await restarted.resume(indexed)
            #expect(bridge.session(id: resumed)?.sessionID == sessionID)
            let sent = sandbox.model.requests.count
            try await bridge.send(SessionMessage(text: "Reply with exactly the word SECOND."), to: resumed)
            try await eventually("接着说的回答到了") { try await replies(store, sessionID).last?.contains("SECOND") == true }
            let request = try #require(sandbox.model.requests.dropFirst(sent).first { $0.prompt.contains("SECOND") })
            #expect(request.said.contains { $0.contains("FIRST") }, "模型收到的对话里没有之前说过的：\(request.said)")
            await restarted.stop()()
        }
    }
}
#endif
