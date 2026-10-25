#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

extension RealOpenCodeTests {
    /// 重新接上（App 重开）：没有标题的会话（模型不存在，这一轮出错，OpenCode 不起标题）仍以首条消息作名字。
    /// 停止接入时只停 CuePad 拉起的服务：终端拉起的不动，CuePad 拉起的停掉。
    @Test func reconnectingKeepsTheFirstMessageAndOnlyTheServiceCuePadStartedIsStopped() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let opencode = try #require(realOpenCodeURL)
            _ = await ChildProcess.run(
                opencode, ["run", "-m", "opencode/no-such-model-xyz", "say hi"], directory: sandbox.work, environment: sandbox.environment,
                timeout: .seconds(120))
            try await eventually("终端的会话出现、名字是首条消息") { session(bridge)?.displayName.contains("say hi") == true }
            let terminalService = try #require(sandbox.service)

            await runtime.stop()()
            #expect(sandbox.service?.pid == terminalService.pid && kill(terminalService.pid, 0) == 0, "终端拉起的服务不动")
            // 第二次重开时会话索引已是最新、不再读对话：首条消息只能从读到哪了里取
            for _ in 0..<2 {
                let reconnected = OpenCodeRuntime(bridge: bridge, paths: sandbox.paths, store: store, hostID: "mac", opencode: { await ExecutableLocator.system.candidates("opencode").first })
                try reconnected.start()
                try await eventually("重新接上") { session(bridge) != nil }
                await quietPeriod(.seconds(2))  // 名字被改写没有事件可等
                #expect(session(bridge)?.displayName.contains("say hi") == true, "名字仍是首条消息：\(String(describing: session(bridge)?.displayName))")
                await reconnected.stop()()
            }

            try await sandbox.run(["service", "stop"])
            try await eventually("服务停了") { kill(terminalService.pid, 0) != 0 }
            let host = OpenCodeRuntime(bridge: bridge, paths: sandbox.paths, store: store, hostID: "mac", opencode: { await ExecutableLocator.system.candidates("opencode").first })
            try host.start()
            _ = try await host.open(in: sandbox.work, launchToken: "t-service", name: nil, model: nil, thinking: nil)
            let started = try #require(sandbox.service)
            await host.stop()()
            try await eventually("CuePad 拉起的服务停掉了") { kill(started.pid, 0) != 0 && sandbox.service == nil }
        }
    }

    @Test func aSessionWhoseModelCannotBeSetIsNotLeftInTheService() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            await #expect(throws: PiBridgeError.unknownModel(.opencode)) {
                _ = try await runtime.open(
                    in: sandbox.work, launchToken: "token-bad", name: "配不上", model: PiModelKey(provider: "opencode", id: "no-such-model"), thinking: nil)
            }
            #expect(session(bridge) == nil)
            let listed = try await sandbox.api("GET", "/api/session")["data"] as? [Any]
            #expect(listed?.isEmpty == true, "服务里还留着：\(String(describing: listed))")
            #expect(try await store.piSessions().isEmpty)
        }
    }

    /// 服务没开：CuePad 自己拉起后台服务开新会话、带图发话、派子代理、远程作答它的提问；停止一轮、结束会话，再接着这个已结束的会话说。
    @Test func cuePadStartsTheServiceAndHostsSessionsFromOpenToResume() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            #expect(sandbox.service == nil)

            let id = try await runtime.open(in: sandbox.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)

            let opened = try #require(bridge.session(id: id))
            #expect(opened.agent == .opencode && opened.hosted && opened.launchToken == "token-1" && sandbox.service != nil)
            let image = pngData(width: 8, height: 8, shade: 0.9)
            try await bridge.send(PiMessage(text: "Reply with exactly the word SEEN.", images: [PiImage(mimeType: "image/png", data: image)]), to: id)
            let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
            try await eventually("带图的那句与回答进了对话") {
                let messages = try await store.piMessages(of: opened.sessionID)
                return messages.contains { $0.role == .known(.user) && $0.text.contains("cuepad://img/\(hash)") }
                    && messages.last?.role == .known(.pi)
            }
            #expect(store.files.fileURL(for: hash) != nil)

            let answered = try await replies(store, opened.sessionID).count
            try await bridge.send(PiMessage(text: "Use the subagent tool with agent explore and description find-readme, prompt: list the files in the current directory. Wait for its result, then reply DONE."), to: id)
            @MainActor func explored() -> Bool {
                session(bridge)?.subagents.contains { $0.name == "find-readme" && $0.role == "explore" && $0.phase == .known(.done) } == true
            }
            // 免费模型偶尔不派子代理就答（实测 big-pickle 说"没有 subagent 工具"）：那样当场报出它的回答，不干等
            try await eventually("子代理出现、做完") {
                if explored() { return true }
                guard session(bridge)?.state == .settled else { return false }
                return try await replies(store, opened.sessionID).count > answered
            }
            let reply = try await replies(store, opened.sessionID).last?.prefix(200)
            #expect(explored(), "模型没派子代理：\(String(describing: reply))")
            try await eventually("这一轮做完") { session(bridge)?.state == .settled }

            try await bridge.send(PiMessage(text: "Use the question tool to ask me one question with header Color and question Which color? with options Red and Blue. After I answer, reply with exactly the color I chose."), to: id)
            try await eventually("在等你回答") { session(bridge)?.question?.kind == .known(.select) }
            let question = try #require(session(bridge)?.question)
            #expect(question.options == ["Red", "Blue"])
            try await bridge.answer(.option("Blue"), to: question.promptID!, in: id)
            try await eventually("按你的回答接着做完") {
                let reply = try await replies(store, opened.sessionID).last
                return session(bridge)?.state == .settled && reply?.contains("Blue") == true
            }

            // OpenCode 的选择题本身允许自己填：从 CuePad 写一个不在选项里的答案
            try await bridge.send(PiMessage(text: "Use the question tool once more: header Color, question Which color now? with options Red and Blue. After I answer, reply with exactly the color I gave."), to: id)
            try await eventually("又在等你回答") { session(bridge)?.question?.kind == .known(.select) }
            let open = try #require(session(bridge)?.question)
            #expect(open.allowsOther)
            try await bridge.answer(.text("Green"), to: open.promptID!, in: id)
            try await eventually("按你自己填的接着做完") {
                let reply = try await replies(store, opened.sessionID).last
                return session(bridge)?.state == .settled && reply?.contains("Green") == true
            }

            let long = PiMessage(text: "Write the numbers from 1 to 400, one per line, each with a long sentence about it.")
            try await bridge.send(PiMessage(text: "Write the numbers from 1 to 30, one per line, each with a short sentence about it."), to: id)
            try await eventually("在忙") { session(bridge)?.state.isWorking == true }
            try await bridge.send(PiMessage(text: "Reply with the word STEERED."), to: id)
            // 这句停下在跑的一轮、开新一轮并做完（模型怎么回不在验收里：免费模型不一定照说）
            try await eventually("这句开的一轮做完") {
                let messages = try await store.piMessages(of: opened.sessionID)
                let said = messages.lastIndex { $0.role == .known(.user) && $0.text.contains("STEERED") }
                return said.map { messages[$0...].contains { $0.role == .known(.pi) } } == true && session(bridge)?.state == .settled
            }

            try await bridge.send(long, to: id)
            try await eventually("又在忙") { session(bridge)?.state.isWorking == true }
            try await bridge.abort(id)
            try await eventually("停下了") { session(bridge)?.state == .settled }

            try await bridge.end(id)
            #expect(bridge.session(id: id) == nil)
            let indexed = try #require(try await store.piSession(opened.sessionID))
            #expect(indexed.agent == .opencode)

            let resumed = try await runtime.resume(indexed)
            #expect(bridge.session(id: resumed)?.sessionID == opened.sessionID)
            let before = try await replies(store, opened.sessionID).count
            // 停得早时那句长的还没回答就留在上下文里：不说明作废，模型会把两句当一个矛盾的要求、用提问工具反问（实测 big-pickle）
            try await bridge.send(PiMessage(text: "The earlier unfinished request is cancelled, do not do it. Reply with exactly the word BACK."), to: resumed)
            try await eventually("接着说的回答到了") {
                try await replies(store, opened.sessionID).count > before || session(bridge)?.question != nil
            }
            #expect(session(bridge)?.question == nil, "模型反问了而没回答：\(String(describing: session(bridge)?.question?.text))")

            try await sandbox.api("DELETE", "/api/session/\(opened.sessionID)")
            try await eventually("删掉的会话下线、索引也删了") {
                let indexed = try await store.piSession(opened.sessionID)
                return bridge.session(id: resumed) == nil && indexed == nil
            }
        }
    }
}
#endif
