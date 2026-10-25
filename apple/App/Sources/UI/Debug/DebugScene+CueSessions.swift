#if DEBUG
import CueStore
import Foundation

/// 演示库里 Cue 页写好之后会话那一侧的样子（`seedCue` 末尾调）：
/// - `-CuePadReplies <N>`：Cue 把歇着的会话留给你回（待回复：Cue 页拍板卡上方那条提示 `CueReplyTip`，看板的等你列，`seedReplies`）；
/// - `-CuePadAtlas <PiWorkState>`、`-CuePadAtlasTitle <名>`：atlas 会话此刻的状态、名字改成这样（核对醒来那几行定格在写下那一刻，不跟着会话变）；
/// - `-CuePadTaskLines written|changed`：对话末尾 Cue 再说一句关于"导入旧数据"的话（气泡下一行这件活），都看过、页停在最新处；
///   changed 再把它与结果卡的"README 截图"改名（标题后加"（改过）"）、换状态（前者做完、后者重开），核对对话里的任务行定格在写下那一刻。
extension DebugScene {
    static func taskLinesIfAsked(_ store: CueStore) async throws {
        guard let mode = defaults.string(forKey: "CuePadTaskLines") else { return }
        let tasks = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
        func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
        guard let importing = task(String(localized: "导入旧数据时保留回收站", table: "Demo")), let panel = task(String(localized: "README 截图换成 Swift 版", table: "Demo")) else { return }
        _ = try await store.addCueMessage(.cue, text: String(localized: "导入旧数据那边我让它先拆成几段读，读完再接着导。", table: "Demo"), task: importing.id)
        try await store.markCueRead(through: .now)
        guard mode == "changed" else { return }
        for task in [importing, panel] {
            try await store.updateCard(task.id) { $0.body = $0.heading + String(localized: "（改过）", table: "Demo") }
            _ = try await store.toggleDone(task.id)
        }
    }

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
        try await settle("header", "header", .codex, minutes: 5, said: String(localized: "名牌两行居中", table: "Demo"), reply: String(localized: "名牌两行已居中，展开改成了 0.25 秒，手感你再试试？", table: "Demo"))
        let project = try await store.projects().first { $0.name == "CuePad" }?.id ?? Project.defaultID
        let task = try await store.createTask(String(localized: "打磨手机 Cue 顶栏", table: "Demo"), in: project)
        try await store.bindSession("header", to: task.id)
        _ = try await store.leaveToYou("header")
        guard count > 1 else { return }
        try await settle("glass", String(localized: "底栏换系统液态玻璃", table: "Demo"), .claudeCode, minutes: 12, said: String(localized: "底栏换成系统的液态玻璃", table: "Demo"), reply: String(localized: "改好了，深色下玻璃边缘偏亮，我调低了 8%。要再看一版截图吗？", table: "Demo"))
        _ = try await store.leaveToYou("glass")
    }
}
#endif
