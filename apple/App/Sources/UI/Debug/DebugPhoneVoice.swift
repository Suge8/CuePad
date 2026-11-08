#if os(iOS) && DEBUG
import CueStore
import Foundation

/// 隔离画面样例只注入远端投影，不创建媒体或冒充命令成功。
/// -CuePadPhoneVoice connecting|listening|muted|processing|speaking|closing|failed|failedRequest|ended
/// -CuePadPhoneVoiceHistory 0|1|200：写入隔离聊天；-CuePadPhoneVoiceEnabled YES：启用隔离 Cue；-CuePadCueDraft 保留输入框草稿。
enum DebugPhoneVoice {
    static func prepare(_ workspace: Workspace) async {
        guard let name = DebugScene.defaults.string(forKey: "CuePadPhoneVoice") else { return }
        let voice = workspace.services.voice
        guard voice.projection == nil else { return }
        let phase: VoiceCallProjection.Phase
        let response: VoiceCallProjection.Response
        switch name {
        case "connecting": (phase, response) = (.connecting, .none)
        case "listening", "muted": (phase, response) = (.listening, .none)
        case "processing": (phase, response) = (.listening, .awaitingAssistant)
        case "speaking": (phase, response) = (.listening, .assistantTurn)
        case "closing": (phase, response) = (.closing, .none)
        case "failedRequest": (phase, response) = (.listening, .none)
        case "failed": (phase, response) = (.failed(.ended(.permissionDenied)), .none)
        case "ended": (phase, response) = (.ended(reason: .hungUp), .none)
        default: return
        }
        let session = VoiceSessionID(UUID())
        let requests: [VoiceCallProjection.Request] = name == "failedRequest" ? [
            .init(reference: .unrecorded(session: session, request: UUID()), recording: false, issue: .storageUnavailable,
                  preview: .init(original: String(localized: "检查发布事项 \(1)", table: "Demo")))
        ] : []
        voice.muted = name == "muted"
        voice.setProjection(.init(session: session, phase: phase, requests: requests, replies: [], executions: [], response: response))
        do {
            let store = workspace.services.store
            if DebugScene.defaults.bool(forKey: "CuePadPhoneVoiceEnabled") {
                try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = "voice-layout-demo" }
            }
            let wanted = DebugScene.defaults.integer(forKey: "CuePadPhoneVoiceHistory")
            let existing = try await store.cueMessages(limit: .max).count
            if wanted > existing {
                for index in existing..<wanted {
                    _ = try await store.addCueMessage(.you, text: String(localized: "检查发布事项 \(index + 1)", table: "Demo"))
                }
            }
            if let draft = DebugScene.defaults.string(forKey: "CuePadCueDraft") { workspace.cue.draft.text = draft }
        } catch { workspace.fail(error) }
    }
}
#endif
