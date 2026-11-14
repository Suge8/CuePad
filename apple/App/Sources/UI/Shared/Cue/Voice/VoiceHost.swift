import CueStore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 通话详情的宿主，Mac 与手机同一个：只读投影（Mac 是自己的完整投影，手机是 Mac 发来的最近一份），
/// 请求、回复正文与会话、停止进度按投影里的身份从库读，不受聊天页面最近 200 条的限制；未落库请求只有投影带的摘要。
struct VoiceHost<Content: View>: View {
    @Environment(Workspace.self) private var workspace
    @State private var records: VoiceRecords?
    let content: (VoiceViewState) -> Content

    var body: some View {
        let state = workspace.voiceViewState
        let ids = state.recordIDs
        content(state.reading(records))
            .observing(workspace.services.store, id: ids, into: $records, onError: workspace.fail) { try VoiceRecords.read(ids, from: $0) }
    }
}

struct VoiceViewState {
    struct Request: Identifiable {
        let reference: VoiceRequestReference
        let message: CueMessage?
        let issue: VoiceIssue?
        let preview: VoiceCallProjection.RequestPreview?
        var id: VoiceRequestReference { reference }
    }

    struct Reply: Identifiable {
        let id: UUID
        let message: CueMessage?
        let readback: VoiceCallProjection.Readback
    }

    struct Execution: Identifiable {
        let session: String
        let turn: TurnTarget?
        /// 同步记录尚未到达时为 nil，不能拿内部标识当标题。
        let item: SessionListItem?
        let stop: DeliveryRequest?
        var id: String { session }
    }

    let phase: VoiceCallProjection.Phase?
    let response: VoiceCallProjection.Response
    let muted: Bool
    let canMute: Bool
    let canRepeat: Bool
    let startUnavailableReason: VoiceIssue?
    let samples: () -> [Double]
    let projection: VoiceCallProjection?
    var requests: [Request] = []
    var replies: [Reply] = []
    var executions: [Execution] = []
    let speech: Speech.Moment
    let shown: (SessionListItem) -> SessionShown

    var recordIDs: VoiceRecordIDs {
        let requests = projection?.requests.compactMap { request -> UUID? in
            if case .recorded(let id) = request.reference { return id }
            return nil
        } ?? []
        return VoiceRecordIDs(
            messages: Array(Set(requests + (projection?.replies.map(\.message) ?? []))).sorted { $0.uuidString < $1.uuidString },
            sessions: Array(Set(projection?.executions.map(\.session) ?? [])).sorted(),
            stops: (projection?.executions.compactMap(\.stop) ?? []).sorted { $0.uuidString < $1.uuidString })
    }

    /// 投影里的身份换上库里读到的记录；records 为 nil（不开详情的通话条）时只有身份。
    func reading(_ records: VoiceRecords?) -> Self {
        var state = self
        let byID = Dictionary(uniqueKeysWithValues: (records?.messages ?? []).map { ($0.id, $0) })
        let stops = Dictionary(uniqueKeysWithValues: (records?.stops ?? []).map { ($0.id, $0) })
        state.requests = (projection?.requests ?? []).map { request in
            let message: CueMessage? = if case .recorded(let id) = request.reference { byID[id] } else { nil }
            return Request(reference: request.reference, message: message, issue: request.issue, preview: request.preview)
        }
        state.replies = (projection?.replies ?? []).map { Reply(id: $0.message, message: byID[$0.message], readback: $0.readback) }
        state.executions = (projection?.executions ?? []).map {
            Execution(session: $0.session, turn: $0.turn, item: records?.executions[$0.session], stop: $0.stop.flatMap { stops[$0] })
        }
        return state
    }

    func presentation(rejection: VoiceCommandResult.Rejection? = nil) -> CueVoicePresentation {
        let activity: CueVoiceActivity = switch phase {
        case nil: .idle
        case .connecting: .connecting
        case .listening, .speaking:
            switch response {
            case .none: .listening
            case .awaitingAssistant: .processing
            case .assistantTurn: .speaking
            }
        case .closing: .closing
        case .failed: .failed
        case .ended: .ended
        }
        var issues: [CueVoicePresentation.Issue] = requests.compactMap { request in
            guard let issue = request.issue else { return nil }
            let excerpt = request.message?.text ?? request.preview?.text
            let message: LocalizedStringResource
            if let excerpt, !excerpt.isEmpty {
                let reason = String(localized: issue.message)
                if request.preview?.truncated == true { message = "请求摘要「\(excerpt)…」：\(reason)" }
                else { message = "请求「\(excerpt)」：\(reason)" }
            } else {
                message = issue.message
            }
            return .init(id: .request(request.reference), summary: "未能交给 Cue", message: message,
                         recovery: excerpt?.isEmpty == false ? .recover(request.reference) : nil)
        }
        if case .failed(let issue) = phase {
            issues.append(.init(id: .connection, summary: "通话未连接", message: issue.message, recovery: issue.recovery))
        } else if case .ended(let reason) = phase, reason != .hungUp {
            let issue = VoiceIssue.ended(reason)
            issues.append(.init(id: .connection, summary: "通话已结束", message: issue.message, recovery: issue.recovery))
        } else if phase == nil, let issue = startUnavailableReason {
            issues.append(.init(id: .connection, summary: "通话暂不可用", message: issue.message, recovery: issue.recovery))
        }
        if let rejection {
            issues.append(.init(id: .store, summary: "操作未执行", message: rejection.message, recovery: nil))
        }
        return .init(activity: activity, muted: muted, samples: { samples().map { CGFloat($0) } }, canMute: canMute, issues: issues,
                     executions: executions.map(execution), readings: replies.map { reply in
                         .init(id: reply.id, excerpt: reply.message.map { CueVoicePresentation.Reading.excerpt(of: $0.text) } ?? String(localized: "回复等待同步"),
                               status: reply.readback.status,
                               recovery: canRepeat && reply.message != nil && reply.readback != .sending && reply.readback != .queued
                                   ? .repeatReply(reply.id) : nil)
                     }, earlier: projection?.omitted.shown,
                     startUnavailableReason: startUnavailableReason?.message)
    }

    /// 停止发出后、受理前说停止的进度（失败、未确认要你看）；受理了或没停过说会话自己的状态。
    private func execution(_ execution: Execution) -> CueVoicePresentation.Execution {
        let trip = execution.stop.map { Speech.trip($0, at: speech) }
        var status = String(localized: "状态等待同步"), attention = false
        if let item = execution.item {
            let header = shown(item)
            status = header.label
            attention = if case .unknown = header.status { true } else { header.needsYou }
        }
        switch trip {
        case .sending?, .sent?: (status, attention) = (String(localized: "正在停止…"), false)
        case .preparing(let reason)?: (status, attention) = (reason, false)
        case .unconfirmed(let reason)?: (status, attention) = (reason, true)
        case .failed(let failure)?: (status, attention) = (failure.text, true)
        case .delivered?, nil: break
        }
        let stopping = execution.item.map {
            MacDelivery.stopping($0.state, deliveries: [$0.delivery, execution.stop].compactMap(\.self), at: speech)
        } ?? false
        return .init(id: execution.session, title: execution.item.map { $0.task?.title ?? $0.state.title } ?? String(localized: "会话等待同步"),
                     status: status, needsAttention: attention,
                     stop: execution.item == nil || stopping ? nil : execution.turn.map { .stop($0) })
    }
}

nonisolated struct VoiceRecords: Equatable, Sendable {
    let messages: [CueMessage]
    let executions: [String: SessionListItem]
    let stops: [DeliveryRequest]

    static func read(_ ids: VoiceRecordIDs, from store: isolated CueStore) throws -> Self {
        try Self(messages: store.cueMessages(ids.messages), executions: store.sessionItems(sessionIDs: ids.sessions),
                 stops: ids.stops.compactMap { try store.deliveryRequest($0) })
    }
}

nonisolated struct VoiceRecordIDs: Equatable, Sendable {
    let messages: [UUID]
    let sessions: [String]
    let stops: [UUID]
}

extension Workspace {
    /// 通话的此刻：阶段与回应来自投影，静音、电平与能不能发起来自本机。不读库，详情里的正文由 `VoiceHost` 补。
    var voiceViewState: VoiceViewState {
        let voice = services.voice
        return .init(phase: voice.phase, response: voice.response, muted: voice.isMuted, canMute: voice.canMute, canRepeat: voice.canRepeat,
                     startUnavailableReason: cue.canHear ? voice.startUnavailableReason : .cueUnavailable,
                     samples: { voice.samples }, projection: voice.projection, speech: services.speech,
                     shown: { [unowned self] in shownInHeader($0.state, delivery: nil) })
    }

    /// 命令结果原样返回，包括拒绝原因；调用方展示结果或传输失败，不自动重发。每次调用一个新的命令身份。
    @discardableResult
    func performVoice(_ action: VoiceAction) async throws -> VoiceCommandResult.Outcome? {
        let voice = services.voice
        switch action {
        case .start:
            #if os(macOS)
            startVoiceCall()
            #else
            callCue()
            #endif
        case .hangUp: await voice.hangUp()
        case .setMuted(let muted): try await voice.setMuted(muted)
        case .recover(let reference): return try await voice.command(.recover(request: reference))
        case .repeatReply(let message): return try await voice.command(.repeatReply(message: message))
        case .stop(let turn): return try await voice.command(.stop(target: turn))
        case .microphoneSettings: try await openMicrophoneSettings()
        }
        return nil
    }

    /// 发出通话的一个动作（静音、挂断、详情里的各项）：结果原样用提示条说，被拒的另交给 `rejected`；不自动重发。
    func runVoice(_ action: VoiceAction, rejected: @escaping (VoiceCommandResult.Rejection) -> Void = { _ in }) {
        Task {
            do {
                switch try await performVoice(action) {
                case .recorded: say("请求已记下")
                case .stopRequested: say("停止请求已提交")
                case .readbackQueued: say("已加入朗读队列")
                case .rejected(let reason):
                    rejected(reason)
                    say(reason.message, tone: .failure)
                case nil: break
                }
            } catch let issue as VoiceIssue {
                say(issue.message, tone: .failure)
            } catch is VoiceSignalError {
                say("通话操作未确认，请检查连接后重试", tone: .failure)
            } catch {
                fail(error)
            }
        }
    }

    private func openMicrophoneSettings() async throws {
        #if os(macOS)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        guard NSWorkspace.shared.open(url) else { throw VoiceIssue.ended(.permissionDenied) }
        #else
        guard await UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) else { throw VoiceIssue.ended(.permissionDenied) }
        #endif
    }
}

/// 详情里最近一次被拒的动作（详情另写一行），提示条已当场说过。
@Observable final class VoiceFeedback {
    var rejection: VoiceCommandResult.Rejection?
}

extension VoiceIssue {
    /// 结束的原因只写原因：下一步是旁边的"重新接通"（提示条、通话详情里都带着它，`recovery`）。
    var message: LocalizedStringResource {
        switch self {
        case .ended(let reason):
            switch reason {
            case .hungUp: "通话已结束"
            case .permissionDenied: "麦克风权限未开启"
            case .audioInterrupted: "音频已中断"
            case .mediaFailed: "通话的声音连接断了"
            case .controlFailed: "通话控制连接断了"
            case .peerLeft: "Mac 已断开连接"
            case .leaseReplaced: "设备连接已更换"
            case .accountChanged: "账号已更换"
            case .networkFailed: "网络连接断了"
            case .timedOut: "通话连接超时"
            case .protocolRejected: "通话协议不兼容，请更新手机和 Mac 上的 CuePad"
            case .relayCapacity: "通话连接已满，请稍后再试"
            }
        case .codexNotInstalled: "请先在 Mac 上安装 Codex"
        case .signedOut: "请先在 Mac 上登录 Codex"
        case .codexUnresponsive: "Codex 没响应，看看 Mac 上的提示"
        case .cueUnavailable: "请先在 Mac 上启用并配置 Cue"
        case .macUnavailable: "无法连接 Mac，请确认 Mac 已开机并联网"
        case .relayUnsupported: "当前连接不支持通话，请更新手机和 Mac 上的 CuePad"
        case .busy: "通话正忙，请稍后再试"
        case .notAllowed(let status): "通话请求被拒绝（\(status)），请在 Mac 上检查账号和语音权限"
        case .server(let status):
            if let status { "通话服务出错（\(status)），请稍后重试" }
            else { "通话服务出错，请稍后重试" }
        case .storageUnavailable: "通话记录暂不可用，请检查 Mac 上的资料库"
        }
    }

    var recovery: VoiceAction? {
        switch self {
        case .ended(.permissionDenied): .microphoneSettings
        case .ended, .server, .codexUnresponsive: .start
        case .codexNotInstalled, .signedOut, .cueUnavailable, .macUnavailable, .relayUnsupported, .busy, .notAllowed, .storageUnavailable: nil
        }
    }
}

private extension VoiceCallProjection.Readback {
    var status: String {
        switch self {
        case .awaitingOrigin: String(localized: "结果来源尚未确认")
        case .queued: String(localized: "等待提交语音")
        case .sending: String(localized: "正在提交语音…")
        case .submitted: String(localized: "已提交语音，朗读尚未确认")
        case .unconfirmed: String(localized: "朗读尚未确认")
        }
    }
}

extension VoiceCommandResult.Rejection {
    var message: LocalizedStringResource {
        switch self {
        case .originalMissing: "原记录不可用，无法继续此操作"
        case .alreadyHandled: "原请求已处理，无需再次提交"
        case .unconfirmed: "原请求的送达尚未确认，不能重复提交"
        case .sourceMismatch: "原请求来源不匹配，操作未执行"
        case .turnChanged: "执行回合已变化，没有停止后来的工作"
        case .unavailable: "操作暂不可用，请稍后再试"
        case .failed: "操作失败，请检查 Mac 上的资料库"
        }
    }
}
