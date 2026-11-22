#if DEBUG && os(macOS)
import CueBridge
import CueStore
import Foundation

extension DebugScene {
    /// `-CuePadSpeak YES`：给会话挂上一段演示的在线会话，一轮一轮地像 Claude Code 那样一小截一小截说出回答（隔一阵停一下），说完落进对话。
    static func speak(_ sessionID: String, services: AppServices) async {
        await running("演示说话") { try await speakRounds(sessionID, services: services) }
    }

    private final class Mute: SessionLink {}
    private static let mute = Mute()

    private static func speakRounds(_ sessionID: String, services: AppServices) async throws {
        let store = services.store
        guard let state = try await store.sessionPage(SessionQuery(id: SessionState.recordID(sessionID: sessionID))).items.first?.state else { return }
        let live = Session.demo(sessionID: sessionID, agent: state.agent.known ?? .pi, cwd: URL(filePath: state.folder ?? "/"))
        services.bridge.attach(live, via: mute)
        let recorder = demoRecorder(store, host: state.hostID, minInterval: .zero)
        func set(_ work: WorkState) async throws {
            _ = try await recorder.update(sessionID: sessionID, state: work, title: state.title, directory: state.folder, projectID: state.projectID)
        }
        var seed: UInt64 = 11
        func roll(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        for round in 0..<100 {
            await Task.wait(for: .seconds(2))
            let seq = Int64(2_000_000 + round * 2)
            let you = ChatMessage(sessionID: sessionID, entryID: "speak-u\(round)", seq: seq, role: .user, text: longChatPrompt(round + 1), at: .now)
            try await store.writeTranscript(SessionTranscript(sessionID: sessionID, messages: [you], recap: Recap(pendingPrompt: you.text)))
            try await set(.thinking)
            await Task.wait(for: .seconds(1.2))
            let reply = Array(spokenReply(round)), since = Date.now
            var at = 0
            while at < reply.count {
                await Task.wait(for: .milliseconds(roll(12) == 0 ? 350 + roll(400) : 25 + roll(40)))
                at = min(reply.count, at + 1 + roll(4))
                services.bridge.setDraft(live.id, LiveDraft(text: String(reply[..<at]), since: since))
            }
            await Task.wait(for: .milliseconds(300))
            services.bridge.setDraft(live.id, nil)
            let answer = ChatMessage(sessionID: sessionID, entryID: "speak-p\(round)", seq: seq + 1, role: .pi, text: String(reply), at: .now, roundStartedAt: you.at)
            try await store.writeTranscript(SessionTranscript(sessionID: sessionID, messages: [answer], recap: Recap(lastPrompt: you.text, lastReply: answer.text)))
            try await set(.settled)
        }
    }

    private static func spokenReply(_ round: Int) -> String {
        switch round % 3 {
        case 0:
            String(localized: "看过了，出字一卡一卡的原因在 Mac 这一侧：四家 Agent 都是一小段一小段推过来的，界面每 100 毫秒才换一次字。\n\n改法是在显示这一层加一个出字时钟：来得多就加速追，来得少就匀速吐完，追平了就停下。", table: "Demo")
        case 1:
            String(localized: "两处要改：\n\n1. 队列按首次加入时间排序，重连不再插到最前。\n2. 登录回调换成统一网关，超时后重试一次。\n\n改完再跑一遍 `scheduler` 的测试。", table: "Demo")
        default:
            String(localized: "第一处改在这里：", table: "Demo") + "\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n"
                + String(localized: "断言也一起改了，12 个用例全部通过。", table: "Demo")
        }
    }
}
#endif
