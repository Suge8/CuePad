#if DEBUG
import CueStore
import Foundation

/// 演示库里 Cue 页写好之后会话那一侧的样子（`seedCue` 末尾调）：
/// - `-CuePadReplies <N>`：Cue 把歇着的会话留给你回（待回复：Cue 页拍板卡上方那条提示 `CueReplyTip`，看板的等你列，`seedReplies`）；
/// - `-CuePadAtlas <PiWorkState>`、`-CuePadAtlasTitle <名>`：atlas 会话此刻的状态、名字改成这样（核对醒来那几行定格在写下那一刻，不跟着会话变）。
extension DebugScene {
    static func atlasIfAsked(_ store: CueStore) async throws {
        let state = defaults.string(forKey: "CuePadAtlas").flatMap(PiWorkState.init(rawValue:))
        let title = defaults.string(forKey: "CuePadAtlasTitle")
        guard state != nil || title != nil else { return }
        _ = try await PiStateRecorder(store: store, hostID: "demo-mac").update(sessionID: "atlas", state: state ?? .tool, title: title ?? "atlas")
    }

    /// 待回复的演示会话（各自新开，不借别的演示已绑着任务的会话）：header 绑着一件新任务"打磨手机 Cue 顶栏"（看板上它挪进等你、卡上写任务名），
    /// 2 起另加没绑任务、十几分钟前歇下的 glass（写会话名）。
    static func seedReplies(_ count: Int, store: CueStore) async throws {
        guard count > 0 else { return }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        func settle(_ id: String, _ title: String, _ agent: AgentKind, minutes: Double, said: String, reply: String) async throws {
            try await recorder.update(
                sessionID: id, state: .settled, title: title, directory: "CuePad",
                times: PiTimes(stateSince: .now.addingTimeInterval(-minutes * 60), busySince: nil), agent: agent)
            try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [], recap: PiRecap(lastPrompt: said, lastReply: reply)))
        }
        try await settle("header", "header", .codex, minutes: 5, said: "名牌两行居中", reply: "名牌两行已居中，展开改成了 0.25 秒，手感你再试试？")
        let project = try await store.projects().first { $0.name == "CuePad" }?.id ?? Project.defaultID
        let task = try await store.createTask("打磨手机 Cue 顶栏", in: project)
        try await store.bindSession("header", to: task.id)
        _ = try await store.leaveToYou("header")
        guard count > 1 else { return }
        try await settle("glass", "底栏换系统液态玻璃", .claudeCode, minutes: 12, said: "底栏换成系统的液态玻璃", reply: "改好了，深色下玻璃边缘偏亮，我调低了 8%。要再看一版截图吗？")
        _ = try await store.leaveToYou("glass")
    }
}
#endif
