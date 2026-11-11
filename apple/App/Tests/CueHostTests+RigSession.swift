#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension CueHostTests.Rig {
    /// 会话要等开工这一轮做完才歇下：同一刻歇下的，状态记进库时可能已落在这一轮前移的基线之前，Cue 就看不到这处变化。
    /// 等的是开工结果之后那句回复、且 Cue 空闲：只等"办好了"会撞上更早一轮的同一句。
    func settleTask(titled title: String) async throws {
        try await say("请建个任务并开工")
        try await eventually("开工这一轮做完") { try await self.store.cueState()?.state == .known(.settled) && self.model.answered("开新会话") }
        try await eventually("执行器开出会话") { !self.app.host.extensions.isEmpty }
        let session = try #require(app.host.extensions.values.first)
        // 假扩展不报会话名，标题取历史索引读会话文件得到的第一句：索引读过（有了检查点）再报状态，几轮的标题才一样。
        // 不认索引里有没有这个会话：投送确认会先按桥上的名字记下它、检查点空着（`seedSession`）
        try await eventually("Mac 读过会话文件") { try await self.store.checkpoint(of: session.sessionID) != nil }
        let task = try #require(try await store.cueBoard().tasks.first?.task)
        // 认领：真实扩展在 hello 里带开会话的标识，假扩展不带，这里直接把叶子绑上它
        try await store.linkCard(task.id, toSession: session.sessionID)
        try await store.updateCard(task.id) { $0.body = title }
        // 开出来的会话一上桥就记成歇着：先等这一轮的在干活写进库，回复才不会早于这一轮的开始（早了不算读到回答，Cue 不醒）
        session.setState(["kind": "thinking"])
        try await eventually("在干活写进库") { try await self.store.sessions(matching: session.sessionID).first?.state.isWorking == true }
        session.setState(["kind": "idle"])
        try await answered(session.sessionID)
    }

    /// 会话这一轮答完、回复是 `reply`。放在歇下写进库之后，是回复晚于状态到的那一路（Claude Code 的轮末标记写在报歇下的钩子之后）：
    /// Cue 读到回复才醒。本机的会话写进会话文件由 Mac 读进库；别的 Mac 上的（这里没有会话文件）替那台 Mac 写它读到的问答。
    func answered(_ sessionID: String, reply: String = "好了") async throws {
        try await eventually("歇下写进库") { try await self.store.sessions(matching: sessionID).first?.state == .known(.settled) }
        guard let file = app.host.sessionFiles[sessionID] else {
            return try await store.writeTranscript(SessionTranscript(sessionID: sessionID, messages: [], recap: Recap(lastPrompt: "接着做", lastReply: reply, answeredAt: .now)))
        }
        try file.reply(reply)
    }
}
#endif
