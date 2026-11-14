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
