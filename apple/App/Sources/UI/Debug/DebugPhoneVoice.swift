#if os(iOS) && DEBUG
import CueStore
import Foundation

/// 隔离画面样例默认只注入远端投影；可选媒体回放边界见 DebugPhoneVoiceReplay，命令仍走正式服务。
/// -CuePadPhoneVoice idle|connecting|listening|muted|processing|speaking|closing|failed|failedRequest|ended|endedUnsent|interrupted
/// （idle 没有通话；failed 是麦克风没授权，interrupted 是音频被打断，endedUnsent 是正常挂断但有一句没交给 Cue）。都当作中转已连上，输入框里的通话钮是能点的样子。
/// -CuePadPhoneVoiceHistory 0|1|200：写入隔离聊天；-CuePadPhoneVoiceEnabled YES：启用隔离 Cue；-CuePadCueDraft 保留输入框草稿。
/// -CuePadPhoneVoicePages YES：注入带续页的隔离投影，分页仍走正式服务，隔离环境无中转时应显示失败。
/// -CuePadPhoneVoiceSessionUnavailable YES：模拟原通话已不存在，点击分页走服务的不可用分支。
/// -CuePadPhoneVoiceRefreshRequired YES：在隔离分页视图注入失效锚点，首页按钮仍调用正式服务。
/// -CuePadPhoneVoiceLastPage YES：注入无续页的末页，核对返回首页入口。
/// -CuePadPhoneVoiceDetails YES：摆好后打开通话详情（没有落点、居中）。
enum DebugPhoneVoice {
    static func prepare(_ workspace: Workspace) async {
        guard let name = DebugScene.defaults.string(forKey: "CuePadPhoneVoice") else { return }
        let voice = workspace.services.voice
        guard voice.projection == nil else { return }
        let phase: VoiceCallProjection.Phase?
        let response: VoiceCallProjection.Response
        switch name {
        case "idle": (phase, response) = (nil, .none)
        case "interrupted": (phase, response) = (.ended(reason: .audioInterrupted), .none)
        case "connecting": (phase, response) = (.connecting, .none)
        case "listening", "muted": (phase, response) = (.listening, .none)
        case "processing": (phase, response) = (.listening, .awaitingAssistant)
        case "speaking": (phase, response) = (.listening, .assistantTurn)
        case "closing": (phase, response) = (.closing, .none)
        case "failedRequest": (phase, response) = (.listening, .none)
        case "failed": (phase, response) = (.failed(.ended(.permissionDenied)), .none)
        case "ended", "endedUnsent": (phase, response) = (.ended(reason: .hungUp), .none)
        default: return
        }
        let session = VoiceSessionID(UUID())
        let requests: [VoiceCallProjection.Request] = name == "failedRequest" || name == "endedUnsent" ? [
            .init(reference: .unrecorded(session: session, request: UUID()), recording: false, issue: .storageUnavailable,
                  preview: .init(original: String(localized: "检查发布事项 \(1)", table: "Demo")))
        ] : []
        voice.muted = name == "muted"
        voice.availability = .ready(endpoint: VoiceEndpoint(device: VoiceDeviceID("voice-layout-phone"), lease: UUID()))
        DebugPhoneVoiceReplay.attach(voice, workspace: workspace, session: session)
        if let phase {
            voice.setProjection(.init(session: session, phase: phase, requests: requests, replies: [], executions: [], response: response))
        }
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
            if DebugScene.defaults.bool(forKey: "CuePadPhoneVoicePages") {
                let reply = try await store.addCueMessage(.cue, text: String(localized: "检查发布事项 \(1)", table: "Demo"))
                let request = VoiceCallProjection.Request(reference: .unrecorded(session: session, request: UUID()), recording: false,
                                                          issue: .storageUnavailable,
                                                          preview: .init(original: String(localized: "检查发布事项 \(1)", table: "Demo")))
                let target = VoiceExecutionTarget(request: UUID(), turn: .init(hostID: "voice-layout-demo", bootID: "demo", sessionID: "demo",
                                                                               deliveryID: UUID(), turnStartedAtMilliseconds: 1))
                var heads = VoicePageHeads()
                heads.requests = .init(version: Data([1]), nextCursor: .init(session: session, list: .requests, after: nil))
                heads.replies = .init(version: Data([1]), nextCursor: .init(session: session, list: .replies, after: nil))
                heads.executions = .init(version: Data([1]), nextCursor: .init(session: session, list: .executions, after: nil))
                voice.session = session
                voice.setProjection(.init(session: session, phase: phase ?? .listening, requests: [request],
                                          replies: [.init(message: reply.id, readback: .submitted)], executions: [target], response: response, pages: heads))
                if DebugScene.defaults.bool(forKey: "CuePadPhoneVoiceSessionUnavailable") { voice.session = nil }
                if DebugScene.defaults.bool(forKey: "CuePadPhoneVoiceLastPage") {
                    let cursor = VoicePageCursor(session: session, list: .requests, after: .request(UUID()))
                    _ = try await voice.requestPages.load(after: cursor) { _ in
                        .init(page: .init(items: [request], nextCursor: nil), version: Data([1]))
                    }
                }
                if DebugScene.defaults.bool(forKey: "CuePadPhoneVoiceRefreshRequired") {
                    do {
                        _ = try await voice.requestPages.load(after: heads.requests.nextCursor) { _ in throw VoicePageError.refreshRequired }
                    } catch VoicePageError.refreshRequired {
                    } catch { workspace.fail(error) }
                }
            }
            if DebugScene.defaults.bool(forKey: "CuePadPhoneVoiceDetails") { workspace.voiceDetails = .unanchored }
        } catch { workspace.fail(error) }
    }
}
#endif
