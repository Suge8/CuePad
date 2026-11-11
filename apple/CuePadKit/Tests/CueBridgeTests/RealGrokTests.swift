#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

/// 端到端：钉住版本的真 Grok（ACP）+ 假模型（Responses，`FakeModel`）+ `GrokRuntime` 与 `Bridge`。零网络、不用任何登录。
@MainActor
@Suite(RealAgents.needs(.grok), RealAgents.tiered)
struct RealGrokTests {
    @Test func aHostedSessionTakesAMessageWithAnImageAndIsConfigured() async throws {
        try await withGrokRig { rig in
            let log = ChangeLog(rig.bridge)
            let id = try await rig.open("token-1")

            let opened = try #require(rig.bridge.session(id: id))
            #expect(opened.agent == .grok && opened.launchToken == "token-1")
            #expect(rig.runsPinnedGrok(id))
            let delivery = UUID()
            let message = SessionMessage(text: "What color is this image? Answer with one lowercase word.", images: [MessageImage(mimeType: "image/png", data: redPNG)], deliveryID: delivery.uuidString)
            try await rig.bridge.send(message, to: id)
            try await eventually("这一轮做完、报了上下文余量、回答落盘") {
                log.states.contains(.thinking) && rig.bridge.session(id: id).map {
                    $0.state == .settled && $0.context?.window ?? 0 > 0 && rig.replies($0).last?.lowercased().contains("red") == true
                } == true
            }

            let request = try #require(rig.asked("What color is this image?").last)
            #expect(request.api == .responses && request.images.first?.hasPrefix("image/png:") == true, "\(request.images)")
            let session = try #require(rig.bridge.session(id: id))
            let mine = try #require(try rig.transcript(session).messages.first { $0.role == .known(.user) })
            #expect(mine.deliveryID == delivery)
            #expect(mine.text.hasPrefix("What color is this image?") && mine.text.contains("![](cuepad://file/"))

            let other = try #require(session.availableModels.first { $0.key.id != session.model?.key.id })
            try await rig.bridge.configure(SessionConfig(model: other.key, thinking: .high, name: "看图"), in: id)
            #expect(rig.bridge.session(id: id)?.model?.key == other.key)
            #expect(rig.bridge.session(id: id)?.thinking == .known(.high))
            #expect(rig.bridge.session(id: id)?.displayName == "看图")
            let unknown = await #expect(throws: BridgeError.unknownModel(.grok)) {
                try await rig.bridge.configure(SessionConfig(model: ModelKey(provider: AgentKind.grok.rawValue, id: "no-such-model")), in: id)
            }
            #expect(unknown?.localizedDescription == "Grok Build 里没有这个模型")
        }
    }

    /// 允许：命令真执行（文件在）；拒绝：命令没执行（文件不在），Grok 把拒绝作为工具结果交给模型，这一轮照常做完。
    @Test(arguments: [true, false]) func aPermissionRequestIsAnsweredFromCuePad(_ allow: Bool) async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-2")
            let marker = rig.work.appending(path: "marker.txt")

            try await rig.bridge.send(SessionMessage(text: "Use the run_terminal_command tool to run exactly: echo ok > marker.txt  Then reply with only DONE."), to: id)
            try await eventually("等你确认") { rig.bridge.session(id: id)?.question != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(question.kind == .known(.confirm) && question.text.contains("echo ok > marker.txt"), "\(question.text)")
            #expect(!FileManager.default.fileExists(atPath: marker.path), "确认之前命令不该执行")

            try await rig.bridge.answer(.confirmed(allow), to: try #require(question.promptID), in: id)

            try await eventually("这一轮做完") { rig.bridge.session(id: id)?.state == .settled }
            #expect(FileManager.default.fileExists(atPath: marker.path) == allow)
            let results = rig.asked("run exactly").filter { $0.step == 1 }
            if allow {
                #expect(rig.replied("DONE", in: id) && results.last?.results.last?.contains("exit: 0") == true, "\(results.map(\.results))")
            } else {
                #expect(results.isEmpty, "拒绝后 Grok 不再请求模型：\(results.map(\.results))")
                try await rig.bridge.send(SessionMessage(text: "Reply with the single word NEXT."), to: id)
                try await eventually("拒绝之后还能接着说") { rig.replied("NEXT", in: id) }
            }
        }
    }

    @Test func aQuestionIsAnsweredFromCuePadOneByOne() async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-ask")
            try await rig.bridge.send(SessionMessage(text: """
                Use the ask_user_question tool once to ask me exactly two single-select questions: "Which drink?" with options Tea \
                (description: hot) and Coffee (description: strong), then "Which size?" with options Small (description: small cup) \
                and Large (description: large cup). Then reply with only my two answers.
                """), to: id)

            try await eventually("问第一问") { rig.bridge.session(id: id)?.question?.options.contains("Coffee") == true }
            let drink = try #require(rig.bridge.session(id: id)?.question)
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            #expect(drink.kind == .known(.select) && Set(drink.options) == ["Tea", "Coffee"] && drink.allowsOther && drink.text.contains("Coffee："), "\(drink)")
            await #expect(throws: BridgeError.rejected("bad_answer")) { try await rig.bridge.answer(.option("Milk"), to: try #require(drink.promptID), in: id) }
            try await rig.bridge.answer(.option("Coffee"), to: try #require(drink.promptID), in: id)

            let size = try #require(rig.bridge.session(id: id)?.question)
            #expect(Set(size.options) == ["Small", "Large"] && size.allowsOther && size.promptID != drink.promptID, "\(size)")
            try await rig.bridge.answer(.text("Medium"), to: try #require(size.promptID), in: id)

            try await eventually("拿到答案接着说，这一轮做完") {
                rig.bridge.session(id: id)?.state == .settled && rig.replied("Coffee", in: id) && rig.replied("Medium", in: id)
            }
            #expect(rig.bridge.session(id: id)?.question == nil)
        }
    }

    @Test func aRunningTurnIsAborted() async throws {
        try await withGrokRig { rig in
            // 说到一半停住（假模型的闸门）：停止一定落在回答还在说的时候
            let gate = rig.model.gate()
            rig.model.on({ $0.prompt.contains("numbers from 1 to 400") }) { _ in .stream(["1\n", "2\n", "3\n"], until: gate) }
            let id = try await rig.open("token-3")
            try await rig.bridge.send(SessionMessage(text: "Write the numbers from 1 to 400, one per line."), to: id)
            try await gate.reached()
            try await eventually("在说") { rig.bridge.session(id: id)?.state == .thinking && rig.bridge.slots.first { $0.id == id }?.draft != nil }

            try await rig.bridge.abort(id)
            try await eventually("停下歇着") { rig.bridge.session(id: id)?.state == .settled }
            try await rig.bridge.send(SessionMessage(text: "Reply with the single word NEXT."), to: id)
            try await eventually("接着回答了") { rig.replied("NEXT", in: id) }
        }
    }

    /// 结束后另起一个 Grok 进程接着这个会话：对话保留（答案只在之前说的话里），新的话得到回答。
    @Test(.tags(.smoke)) func anEndedSessionIsResumedByANewProcessWithItsConversation() async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-4")
            try await rig.bridge.send(SessionMessage(text: "Remember the word PAPAYA. Reply with only OK."), to: id)
            try await eventually("记下了") { rig.replied("OK", in: id) && rig.bridge.session(id: id)?.state == .settled }
            let session = try #require(rig.bridge.session(id: id))
            let pid = try #require(session.pid)

            try await rig.bridge.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let file = try #require(session.sessionFile)
            let resumed = try await rig.runtime.resume(IndexedSession(id: session.sessionID, path: file.path, cwd: rig.work.path, lastActivityAt: .now, agent: .grok))
            let back = try #require(rig.bridge.session(id: resumed))
            #expect(back.sessionID == session.sessionID && back.pid != pid && rig.runsPinnedGrok(resumed))
            try await rig.bridge.send(SessionMessage(text: "What word did I ask you to remember? Reply with only the word."), to: resumed)
            try await eventually("接着回答了") { rig.replied("PAPAYA", in: resumed) }
        }
    }

    /// 终端里还开着这个会话（真的终端界面）时不接，它退出后照常接着。
    @Test func aSessionStillOpenInATerminalIsNotResumedUntilItExits() async throws {
        try await withGrokRig { rig in
            let id = try await rig.open("token-5")
            try await rig.bridge.send(SessionMessage(text: "Remember the word PAPAYA. Reply with only OK."), to: id)
            try await eventually("记下了") { rig.replied("OK", in: id) && rig.bridge.session(id: id)?.state == .settled }
            let session = try #require(rig.bridge.session(id: id))
            let indexed = IndexedSession(
                id: session.sessionID, path: try #require(session.sessionFile).path, cwd: rig.work.path, lastActivityAt: .now, agent: .grok)
            try await rig.bridge.end(id)
            try await eventually("下线") { rig.bridge.session(id: id) == nil }

            let terminal = try await rig.terminal(resuming: session.sessionID)
            do {
                try await eventually("终端里开着") { GrokRuntime.openSessions(in: rig.home).contains(session.sessionID) }
                await #expect(throws: AgentRuntimeError.openElsewhere) { try await rig.runtime.resume(indexed) }
                #expect(rig.bridge.session(sessionID: session.sessionID) == nil)
            } catch {
                await terminal.stop()
                throw error
            }
            await terminal.stop()
            // `script` 把 Grok 放在自己的会话里：它走了伪终端才挂断，Grok 随后才退出
            try await eventually("终端里退出了") { !GrokRuntime.openSessions(in: rig.home).contains(session.sessionID) }

            let resumed = try await rig.runtime.resume(indexed)
            #expect(rig.bridge.session(id: resumed)?.sessionID == session.sessionID)
        }
    }
}
#endif
