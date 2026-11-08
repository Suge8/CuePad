#if os(iOS)
import SwiftUI
import UIKit

extension PhoneVoiceAction: CueVoiceOperation {
    var title: LocalizedStringResource {
        switch self {
        case .start: "重新接通"
        case .hangUp: "挂断"
        case .setMuted: "静音"
        case .recover: "重新交给 Cue"
        case .repeatReply: "再说一遍"
        case .stop: "停止执行"
        case .microphoneSettings: "打开麦克风设置"
        }
    }
}

extension VoiceIssue {
    var phoneMessage: LocalizedStringResource {
        switch self {
        case .ended(let reason):
            switch reason {
            case .hungUp: "通话已结束"
            case .background: "App 进入后台，通话已结束"
            case .permissionDenied: "麦克风权限未开启，请在设置中允许 CuePad 使用麦克风"
            case .audioInterrupted: "声音被其他应用打断，请重新接通"
            case .mediaFailed: "通话的声音连接断了，请重新接通"
            case .controlFailed: "通话控制连接断了，请重新接通"
            case .peerLeft: "Mac 已断开连接，请检查 Mac 后重新接通"
            case .leaseReplaced: "设备连接已更换，请重新接通"
            case .accountChanged: "账号已更换，请重新接通"
            case .networkFailed: "网络连接断了，请检查网络后重新接通"
            case .timedOut: "通话连接超时，请重新接通"
            case .protocolRejected: "通话协议不兼容，请更新手机和 Mac 上的 CuePad"
            case .relayCapacity: "通话连接已满，请稍后再试"
            }
        case .codexNotInstalled: "请先在 Mac 上安装 Codex"
        case .signedOut: "请先在 Mac 上登录 Codex"
        case .cueUnavailable: "请先在 Mac 上启用并配置 Cue"
        case .macUnavailable: "无法连接 Mac，请确认 Mac 已开机并联网"
        case .relayUnsupported: "当前连接不支持通话，请更新手机和 Mac 上的 CuePad"
        case .busy: "通话正忙，请稍后再试"
        case .notAllowed(let status): "通话请求被拒绝（\(status)），请在 Mac 上检查账号和语音权限"
        case .server(let status):
            if let status { "通话服务出错（\(status)），请稍后重试" }
            else { "通话服务出错，请稍后重试" }
        case .storageUnavailable: "通话记录暂不可用，请检查 Mac 上的资料库"
        case .originalMissing: "原记录不可用，无法继续此操作"
        case .alreadyHandled: "原请求已处理，无需再次提交"
        case .turnChanged: "执行回合已变化，没有停止后来的工作"
        case .shutdownUnconfirmed: "通话关闭尚未确认，请检查连接"
        }
    }

    var phoneRecovery: PhoneVoiceAction? {
        if actions.contains(.microphoneSettings) { return .microphoneSettings }
        if actions.contains(.reconnect) { return .start }
        return nil
    }
}

extension PhoneVoiceViewState {
    func shared(rejection: VoiceCommandResult.Rejection? = nil) -> CueVoiceState<PhoneVoiceAction> {
        let activity: CueVoiceActivity = switch phase {
        case nil: .idle
        case .connecting: .connecting
        case .listening, .processing, .speaking:
            switch response {
            case .none: .listening
            case .awaitingAssistant: .processing
            case .assistantTurn: .speaking
            }
        case .closing: .closing
        case .failed: .failed
        case .ended: .ended
        }
        var issues: [CueVoiceState<PhoneVoiceAction>.Issue] = requests.compactMap { request in
            guard let issue = request.issue else { return nil }
            return .init(id: .request(AnyHashable(request.reference)), summary: "未能交给 Cue", message: issue.phoneMessage,
                         recovery: request.message == nil ? nil : .recover(request.reference))
        }
        if case .failed(let issue) = phase {
            issues.append(.init(id: .connection, summary: "通话未连接", message: issue.phoneMessage, recovery: issue.phoneRecovery))
        } else if case .ended(let reason) = phase, reason != .hungUp, reason != .background {
            let issue = VoiceIssue.ended(reason)
            issues.append(.init(id: .connection, summary: "通话已结束", message: issue.phoneMessage, recovery: issue.phoneRecovery))
        } else if phase == nil, let issue = startUnavailableReason {
            issues.append(.init(id: .connection, summary: "通话暂不可用", message: issue.phoneMessage, recovery: issue.phoneRecovery))
        }
        if let rejection {
            issues.append(.init(id: .store, summary: "操作未执行", message: rejection.phoneMessage, recovery: nil))
        }
        return .init(activity: activity, muted: muted, samples: { samples().map { CGFloat($0) } }, canMute: canMute,
                     issues: issues, canStopExecution: false,
                     executions: executions.map { execution in
                         .init(id: "\(execution.target.request)-\(execution.target.turn.deliveryID)-\(execution.target.turn.turnStartedAtMilliseconds)",
                               title: execution.title ?? String(localized: "会话等待同步"),
                               status: execution.status?.label ?? String(localized: "状态等待同步"),
                               stop: execution.title == nil ? nil : .stop(execution.target))
                     }, readings: replies.map { reply in
                         .init(id: reply.id, excerpt: reply.message.map { String($0.text.prefix(80)) } ?? String(localized: "回复等待同步"),
                               status: reply.readback.phoneStatus,
                               recovery: activity != .ended && activity != .failed && reply.message != nil && reply.readback != .sending && reply.readback != .queued
                                   ? .repeatReply(reply.id) : nil)
                     }, startUnavailableReason: startUnavailableReason?.phoneMessage)
    }
}

private extension VoiceCallProjection.Readback {
    var phoneStatus: String {
        switch self {
        case .awaitingOrigin: String(localized: "结果来源尚未确认")
        case .queued: String(localized: "等待提交语音")
        case .sending: String(localized: "正在提交语音…")
        case .submitted: String(localized: "已提交语音，朗读尚未确认")
        case .unconfirmed: String(localized: "朗读尚未确认")
        }
    }
}

struct CueVoicePanel: View {
    @Environment(Workspace.self) private var workspace
    @State private var feedback = PhoneVoiceFeedback()

    var body: some View {
        let state = workspace.phoneVoiceViewState
        CueVoiceView(presentation: state.shared(rejection: feedback.rejection), detailsSource: Bindable(workspace).voiceDetails,
                     start: { run(.start, perform: workspace.performPhoneVoice) }, action: { intent in
            switch intent {
            case .toggleMute: run(.setMuted(!state.muted), perform: workspace.performPhoneVoice)
            case .hangUp: run(.hangUp, perform: workspace.performPhoneVoice)
            case .perform(let operation): run(operation, perform: workspace.performPhoneVoice)
            case .stopExecution: break
            }
        })
        .panel(isPresented: Binding { workspace.voiceDetails != nil } set: { if !$0 { workspace.voiceDetails = nil } },
               style: .bubble(workspace.voiceDetails ?? .unanchored, width: .fixed(360))) {
            PhoneVoiceHost { state, perform in
                CueVoiceDetails(presentation: { state.shared(rejection: feedback.rejection) }, action: { intent in
                    if case .perform(let operation) = intent { run(operation, perform: perform) }
                })
            }
        }
        .task { await DebugHooks.preparePhoneVoice(workspace) }
    }

    private func run(_ action: PhoneVoiceAction, perform: @escaping (PhoneVoiceAction) async throws -> VoiceCommandResult.Outcome?) {
        Task {
            do {
                if let result = try await perform(action) { report(result) }
            } catch let issue as VoiceIssue {
                workspace.say(issue.phoneMessage, tone: .failure)
            } catch is VoiceSignalError {
                workspace.say("通话操作未确认，请检查连接后重试", tone: .failure)
            } catch {
                workspace.fail(error)
            }
        }
    }

    private func report(_ result: VoiceCommandResult.Outcome) {
        switch result {
        case .recorded: workspace.say("请求已记下")
        case .stopRequested: workspace.say("停止请求已提交")
        case .readbackQueued: workspace.say("已加入朗读队列")
        case .rejected(let reason):
            feedback.rejection = reason
            workspace.say(reason.phoneMessage, tone: .failure)
        }
    }
}

@Observable private final class PhoneVoiceFeedback {
    var rejection: VoiceCommandResult.Rejection?
}

private extension VoiceCommandResult.Rejection {
    var phoneMessage: LocalizedStringResource {
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
#endif
