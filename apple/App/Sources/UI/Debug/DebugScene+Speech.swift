#if DEBUG
import CueStore
import SwiftUI

/// `-CuePadSpeech <draft|sent>`（配 cue 或 session 画面与 `-CuePadDemo YES`，iOS 与 Mac）：去处是 Cue 页（cue），或 `-CuePadSession` 那个会话的回复框（session；
/// 演示里 scratch 没说过话，末尾只有这一句）。
/// draft 在输入框里写一句、不发；sent 再经发消息的那条路（`Workspace.speak`）发出：输入框已空，末尾一个发送中的气泡（演示里没有接收的 Mac，一直在路上）。
/// 已送达与没能送达：Cue 页用 `-CuePadCuePresence thinking|asleep`（`DebugScene+Cue.swift`），会话页看 relay（一句已送达、一句没能送达）。
extension DebugScene {
    static func presetSpeech(_ workspace: Workspace) async {
        guard let speech = defaults.string(forKey: "CuePadSpeech") else { return }
        let services = workspace.services, files = services.store.files
        let box: Binding<ComposerDraft>, listener: Listener
        if scene == "session" {
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            guard let session = try? await services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state
            else { return }
            box = services.settings.replyDraftBinding(for: session.id)
            listener = .session(session, mode: .send)
        } else {
            box = Bindable(workspace.cue).draft
            listener = .cue
        }
        box.wrappedValue.text = "把重连用例也跑一遍，结果贴给我"
        if speech == "sent" { _ = workspace.speak(to: listener, from: box) { try $0.stored(in: files) } }
    }
}
#endif
