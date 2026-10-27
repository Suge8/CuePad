#if DEBUG
import CueStore
import SwiftUI

/// `-CuePadSpeech <draft|sent|send|press>`（配 cue 或 session 画面与 `-CuePadDemo YES`，iOS 与 Mac）：去处是 Cue 页（cue），或 `-CuePadSession` 那个会话的回复框（session；
/// 演示里 scratch 没说过话，末尾只有这一句）。
/// draft 在输入框里写一句、不发；sent 再经发消息的那条路（`Workspace.speak`）发出：输入框已空，末尾一个发送中的气泡（演示里没有接收的 Mac，一直在路上）；
/// send 先写好、画面就绪 2 秒后再发（录屏看到发出的那一下，配 `-CuePadDemoMac YES` 看到送达）；press 同 send，但在输入框出现 3 秒（`-CuePadPressAfter`）后按的是它的发送钮（看钮与飞光；Mac 上给录屏留出起录的时间）；
/// 配 `-CuePadFlightLog <路径>` 从按下起量一段（同叫醒的量法，`measureFlight`）；配 `-CuePadFiles YES` 这句带上一张图与一份 PDF（看你的话里的附件）。
/// 已送达与没能送达：Cue 页用 `-CuePadCuePresence thinking|asleep`（`DebugScene+Cue.swift`），会话页看 relay（一句已送达、一句没能送达）。
/// trips（配 `-CuePadSession relay -CuePadSync simulated`，新的隔离库）：再写一句给一台不接手的 Mac（demo-studio），传上替身 iCloud 后是已发出——
/// 一页里三种状态（已发出、已送达、没能送达）。
extension DebugScene {
    static func presetSpeech(_ workspace: Workspace) async {
        await running("预设说话") { try await presetSpeechBody(workspace) }
    }

    private static func presetSpeechBody(_ workspace: Workspace) async throws {
        guard let speech = defaults.string(forKey: "CuePadSpeech") else { return }
        let services = workspace.services
        let box: Binding<ComposerDraft>, listener: Listener
        if scene == "session" {
            let title = defaults.string(forKey: "CuePadSession") ?? "homepage"
            guard let session = try await services.store.piSessionPage(PiSessionQuery(text: title)).items.first(where: { $0.state.title == title })?.state
            else { return }
            box = services.settings.replyDraftBinding(for: session.id)
            listener = .session(session, mode: .send)
        } else {
            box = Bindable(workspace.cue).draft
            listener = .cue
        }
        box.wrappedValue.text = String(localized: "把重连用例也跑一遍，结果贴给我", table: "Demo")
        if defaults.bool(forKey: "CuePadFiles") {
            let pdf = try demoPDF(services.store)
            let image = try services.store.files.store(swatch(red: 0.85, green: 0.47, blue: 0.29))
            box.wrappedValue.files = [DraftFile(key: image, name: ""), pdf]
        }
        switch speech {
        case "sent": workspace.speak(to: listener, from: box) { $0.stored }
        case "trips":
            // 会话在哪台就发给哪台（`CueStore.speak`），所以直接写请求、指给那台不接手的，再像发出时那样马上传
            guard case .session(let target, _, _, _) = listener, let ref = target.ref else { return }
            let request = try await services.store.requestDelivery(box.wrappedValue.text, to: target, on: Self.idleMac, mode: .send)
            box.wrappedValue.text = ""
            await services.upload(request.id)
            // 这一页的话都有了着落再报就绪：交给 demo-mini 的有了结果，发给不接手的那台的传上了替身
            let settled = services.store.observe { store in
                try store.deliveryRequests(toSession: ref).allSatisfy { !$0.isOpen || $0.hostID == Self.idleMac && $0.reachedServer }
            }
            for try await done in settled where done { break }
        case "send":
            Task {
                await Task.wait(for: .seconds(2))
                workspace.speak(to: listener, from: box) { $0.stored }
            }
        default: break
        }
    }

    /// `trips` 那一句发去的 Mac：演示库里没有它的执行器，话只到服务器（已发出）。
    nonisolated private static let idleMac = "demo-studio"

    static func pressSendIfAsked(session: Bool, _ press: () -> Void) async {
        if !session, cueFlows { return await pressForCueFlow(press) }
        guard defaults.string(forKey: "CuePadSpeech") == "press", (scene == "session") == session else { return }
        // 等的这几秒里输入框可能重建（页面换了身份）：旧的那个任务被取消，不能再按、再量，否则一次按下记成两条
        guard await Task.wait(for: .seconds(seconds("CuePadPressAfter", default: 3))) else { return }
        guard let log = defaults.string(forKey: "CuePadFlightLog").map({ URL(fileURLWithPath: $0) }) else { return press() }
        await running("量按下发送") { try await measureFlight("press", seconds: flightProbe, into: log, act: press) }
    }
}
#endif
