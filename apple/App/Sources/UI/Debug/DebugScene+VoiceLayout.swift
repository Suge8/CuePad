#if os(macOS) && DEBUG
import CuePi
import CueStore
import Foundation

/// 正式页面的隔离布局验收：-CuePadVoiceLayout listening|ended|failed|idle，-CuePadVoiceHistory 0|1|200。
/// -CuePadVoiceReadings YES：接通后写入两条真实库结果，等提交后挂断，验收重连后的逐条主动重说。
/// 只替换声音与网络边界，不连接麦克风；库、聊天、按钮及异步关闭仍走正式宿主。
/// close 的短延迟模拟设备释放，用来检查关闭中的操作；不代表真实通话或音轨证据。
extension DebugScene {
    static func voiceLayoutIfAsked(_ workspace: Workspace) async {
        guard let state = defaults.string(forKey: "CuePadVoiceLayout") else { return }
        await running("通话布局") {
            let store = workspace.services.store
            try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "voice-layout-demo" }
            let count = defaults.integer(forKey: "CuePadVoiceHistory")
            let existing = try await store.cueMessages(limit: .max).filter { $0.author == .known(.you) }.count
            for index in existing..<max(existing, count) {
                let request = try await store.addCueMessage(.you, text: String(localized: "检查发布事项 \(index + 1)", table: "Demo"))
                try await store.markCueMessagesDelivered([request.id])
                _ = try await store.addCueMessage(.cue, text: String(localized: "**演示结果 \(index + 1)**\n\n- 核对 Mac 界面\n- 核实手机接入", table: "Demo"), answeredRequests: [request.id])
            }
            if let ask = defaults.string(forKey: "CuePadCueAsk") { try await seedAsk(ask, store: store, task: nil) }
            if let draft = defaults.string(forKey: "CuePadCueDraft") { workspace.cue.draft.text = draft }
            for await ready in Observations({ workspace.cue.canHear }) where ready { break }
            workspace.showCue()
            guard state != "idle" else { return }
            workspace.startVoiceCall()
            guard let call = workspace.voice else { return }
            for await phase in Observations({ call.phase }) where phase == .listening { break }
            if defaults.bool(forKey: "CuePadVoiceReadings") {
                for index in 1...2 {
                    _ = try await store.addCueMessage(.cue, text: String(localized: "**演示结果 \(index)**\n\n- 核对 Mac 界面\n- 核实手机接入", table: "Demo"), answeredRequests: [])
                }
                for await submitted in Observations({ call.replies.count == 2 && call.replies.allSatisfy { $0.delivery == .submitted } }) where submitted { break }
            }
            if state == "ended" { call.hangUp() }
            if state == "failed" { call.inputs.continuation.yield(.failed(.media)) }
            if state == "ended" || state == "failed" {
                for await live in Observations({ call.isLive }) where !live { break }
            }
        }
    }
}

final class DebugVoiceLayoutMedia: VoiceMedia {
    var onEvent: (VoicePeer.Event) -> Void = { _ in }
    func offer() async throws -> String { "layout-offer" }
    func accept(answer: String) async throws { onEvent(.connected) }
    func play() async throws {}
    func setMuted(_ value: Bool) async throws {}
    func close() async throws { try await Task.sleep(for: .seconds(2)) }
}

final class DebugVoiceLayoutControl: VoiceControl {
    func send(_ outgoing: VoiceWire.Outgoing) async throws {}
    func close() {}
}
#endif
