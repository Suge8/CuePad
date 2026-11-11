#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

extension RealOpenCodeTests {
    /// 用户的服务先开着，终端里也开了会话：只有 CuePad 开的会话上桥、进索引；接入停了再开（同 App 重启），靠资料库里记下的托管认回它，
    /// 首条消息还在，终端的会话照样不理；用户的服务不随接入停，CuePad 拉起的才停。
    @Test func reconnectingRecognisesOnlyHostedSessionsAndOnlyTheServiceCuePadStartedIsStopped() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            var mirror = SessionMirror(recorder: StateRecorder(store: store, hostID: "mac"))
            let changes = bridge.changes()
            let recording = Task { for await change in changes { _ = try? await mirror.apply(change) } }
            defer { recording.cancel() }
            try await sandbox.run(["service", "start"])
            try await sandbox.run(["run", "Reply with exactly the word PONG and nothing else."])
            let terminal = try #require((try await sandbox.api("GET", "/api/session")["data"] as? [[String: Any]])?.first?["id"] as? String)

            let id = try await runtime.open(in: sandbox.work, launchToken: "t-hosted", name: nil, model: nil, thinking: nil)
            let hosted = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word HOSTED."), to: id)
            try await eventually("托管的那句答完") { try await replies(store, hosted).last?.contains("HOSTED") == true && session(bridge)?.state == .settled }
            try await eventually("托管记进资料库") { try await store.hostedSessionIDs(of: .opencode, host: "mac") == [hosted] }
            #expect(bridge.sessions.map(\.sessionID) == [hosted])
            #expect(try await store.indexedSession(terminal) == nil, "终端的会话进了索引")
            let userService = try #require(sandbox.service)

            await runtime.stop()()
            #expect(sandbox.service?.pid == userService.pid && kill(userService.pid, 0) == 0, "用户的服务不动")
            // 第二次重开时会话索引已是最新、不再读对话：首条消息只能从读到哪了里取
            for _ in 0..<2 {
                let reconnected = sandbox.runtime(bridge, store)
                try reconnected.start()
                try await eventually("重新接上托管的会话") { session(bridge) != nil }
                await quietPeriod(.seconds(2))  // 终端的会话被接上、首条消息丢掉都没有事件可等
                #expect(bridge.sessions.map(\.sessionID) == [hosted])
                #expect(session(bridge)?.firstMessage?.contains("HOSTED") == true, "首条消息：\(String(describing: session(bridge)?.firstMessage))")
                #expect(try await store.indexedSession(terminal) == nil)
                await reconnected.stop()()
            }

            try await sandbox.run(["service", "stop"])
            try await eventually("服务停了") { kill(userService.pid, 0) != 0 }
            let host = sandbox.runtime(bridge, store)
            try host.start()
            _ = try await host.open(in: sandbox.work, launchToken: "t-service", name: nil, model: nil, thinking: nil)
            let started = try #require(sandbox.service)
            await host.stop()()
            try await eventually("CuePad 拉起的服务停掉了") { kill(started.pid, 0) != 0 && sandbox.service == nil }
        }
    }

    /// 升级前留在库里的非托管历史（索引与已结束的记录）：托管会话的快照、重连、删除都不动它，投送也读不了它的对话。
    @Test func anUnhostedSessionLeftInTheIndexStaysThroughSnapshotReconnectAndDeletion() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            let foreign = IndexedSession(
                id: "ses_terminal", path: OpenCodeRuntime.path("ses_terminal"), cwd: sandbox.work.path, title: "终端里的", lastActivityAt: .now, agent: .opencode)
            try await store.upsertSession(foreign, host: "mac")
            func kept() async throws -> Bool {
                let state = try await store.sessionItems(sessionIDs: [foreign.id])[foreign.id]?.state.state
                return try await store.indexedSession(foreign.id) != nil && state == .known(.ended)
            }

            let id = try await runtime.open(in: sandbox.work, launchToken: "t-own", name: nil, model: nil, thinking: nil)
            let hosted = try #require(bridge.session(id: id)?.sessionID)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word OWN."), to: id)
            try await eventually("托管的那句答完、进了索引") {
                let indexed = try await store.indexedSession(hosted)
                return try await replies(store, hosted).last?.contains("OWN") == true && indexed != nil
            }
            await quietPeriod(.seconds(2))  // 快照后的回填对账没有事件可等
            #expect(try await kept(), "连上后的回填删了非托管的历史")
            await #expect(throws: BridgeError.unknownSession(foreign.id)) { try await runtime.transcript(of: foreign, files: store.files) }

            await runtime.stop()()
            let reconnected = sandbox.runtime(bridge, store)
            try reconnected.start()
            _ = try await reconnected.resume(try #require(try await store.indexedSession(hosted)))
            await quietPeriod(.seconds(2))
            #expect(try await kept(), "重连后的回填删了非托管的历史")

            try await sandbox.api("DELETE", "/api/session/\(hosted)")
            try await eventually("删掉的托管会话索引也删了") { try await store.indexedSession(hosted) == nil }
            #expect(try await kept(), "删一个托管会话连带删了非托管的历史")
            await reconnected.stop()()
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
            #expect(try await store.indexedSessions().isEmpty)
        }
    }

    @Test func cuePadStartsTheServiceAndHostsSessionsFromOpenToResume() async throws {
        try await withOpenCode { sandbox, store, bridge, runtime in
            #expect(sandbox.service == nil)

            let id = try await runtime.open(in: sandbox.work, launchToken: "token-1", name: nil, model: nil, thinking: nil)

            let opened = try #require(bridge.session(id: id))
            #expect(opened.agent == .opencode && opened.launchToken == "token-1" && sandbox.service != nil)
            let image = pngData(width: 8, height: 8, shade: 0.9)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word SEEN.", images: [MessageImage(mimeType: "image/png", data: image)]), to: id)
            let hash = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined() + ".png"
            try await eventually("带图的那句与回答进了对话") {
                let messages = try await store.chatMessages(of: opened.sessionID)
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
            let indexed = try #require(try await store.indexedSession(opened.sessionID))
            #expect(indexed.agent == .opencode)

            let resumed = try await runtime.resume(indexed)
            #expect(bridge.session(id: resumed)?.sessionID == opened.sessionID)
            try await bridge.send(SessionMessage(text: "Reply with exactly the word BACK."), to: resumed)
            try await eventually("接着说的回答到了") { try await replies(store, opened.sessionID).last?.contains("BACK") == true }

            try await sandbox.api("DELETE", "/api/session/\(opened.sessionID)")
            try await eventually("删掉的会话下线、索引也删了") {
                let indexed = try await store.indexedSession(opened.sessionID)
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
            let indexed = try #require(try await store.indexedSession(sessionID))

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
