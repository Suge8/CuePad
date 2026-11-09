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
        case .requests: "请求记录"
        case .replies: "朗读记录"
        case .executions: "执行记录"
        case .microphoneSettings: "设置"
        }
    }
}

extension VoiceIssue {
    /// 结束的原因只写原因：下一步是旁边的"重新接通"（提示条、通话详情里都带着它，`phoneRecovery`）。
    var phoneMessage: LocalizedStringResource {
        switch self {
        case .ended(let reason):
            switch reason {
            case .hungUp: "通话已结束"
            case .background: "App 进入后台，通话已结束"
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
        let sessionUnavailable = [requestPage.error, replyPage.error, executionPage.error].contains(.sessionUnavailable)
        var issues: [CueVoiceState<PhoneVoiceAction>.Issue] = requests.compactMap { request in
            guard let issue = request.issue else { return nil }
            let excerpt = request.message?.text ?? request.preview?.text
            let message: LocalizedStringResource
            if let excerpt, !excerpt.isEmpty {
                let reason = String(localized: issue.phoneMessage)
                if request.preview?.truncated == true { message = "请求摘要「\(excerpt)…」：\(reason)" }
                else { message = "请求「\(excerpt)」：\(reason)" }
            } else {
                message = issue.phoneMessage
            }
            return .init(id: .request(AnyHashable(request.reference)), summary: "未能交给 Cue", message: message,
                         recovery: !sessionUnavailable && excerpt?.isEmpty == false ? .recover(request.reference) : nil)
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
                               stop: sessionUnavailable || execution.title == nil ? nil : .stop(execution.target))
                     }, readings: replies.map { reply in
                         .init(id: reply.id, excerpt: reply.message.map { String($0.text.prefix(80)) } ?? String(localized: "回复等待同步"),
                               status: reply.readback.phoneStatus,
                               recovery: !sessionUnavailable && canRepeat && reply.message != nil && reply.readback != .sending && reply.readback != .queued
                                   ? .repeatReply(reply.id) : nil)
                     }, requestPage: phase == nil ? nil : page(requestPage, sessionUnavailable: sessionUnavailable, action: PhoneVoiceAction.requests),
                     replyPage: phase == nil ? nil : page(replyPage, sessionUnavailable: sessionUnavailable, action: PhoneVoiceAction.replies),
                     executionPage: phase == nil ? nil : page(executionPage, sessionUnavailable: sessionUnavailable, action: PhoneVoiceAction.executions),
                     startUnavailableReason: startUnavailableReason?.phoneMessage)
    }

    private func page(_ page: Page, sessionUnavailable: Bool, action: (VoicePageCursor?) -> PhoneVoiceAction) -> CueVoiceState<PhoneVoiceAction>.Page? {
        let first = !sessionUnavailable && (page.canReturnToHead || page.error != nil) ? action(nil) : nil
        let next = sessionUnavailable ? nil : page.next.map { action($0) }
        let error = page.error?.phoneMessage
        guard first != nil || next != nil || page.loading || error != nil else { return nil }
        return .init(first: first, next: next, loading: page.loading, error: error)
    }
}

private extension VoicePageError {
    var phoneMessage: LocalizedStringResource {
        switch self {
        case .refreshRequired: "记录已变化，请回到首页"
        case .sessionUnavailable: "原通话已被替换或不可用，请在 Mac 的通话详情查看或恢复原请求"
        case .unavailable: "无法读取通话记录，请检查连接后重试"
        case .tooLarge: "这条通话记录太大，无法读取"
        case .storageUnavailable: "通话记录暂不可用，请检查 Mac 上的资料库"
        }
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

/// 手机通话条（`CueVoiceView`）盖在"对 Cue 说"那块玻璃上（`CueComposer` 让出它，`Composer.yielded`），与它的通话详情。
/// 只读投影（`phoneVoiceViewState`），动作经 `performPhoneVoice`；动作的结果与被拒当场用提示条说。条只在通话中（`active`）。
struct PhoneCall: ViewModifier {
    let active: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var feedback = PhoneVoiceFeedback()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if active {
                    // 与输入框一行时同高：静音、挂断正对"＋"与发送
                    PhoneCallBar(feedback: feedback)
                        .frame(height: ComposerMetrics.lineSlot(line: ComposerField.lineHeight(typeSize)))
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: active)
            .panel(isPresented: Binding { workspace.voiceDetails != nil } set: { if !$0 { workspace.voiceDetails = nil } },
                   style: .bubble(workspace.voiceDetails ?? .unanchored, width: .fixed(360))) {
                PhoneVoiceHost { state, perform in
                    CueVoiceDetails(presentation: { state.shared(rejection: feedback.rejection) }, action: { intent in
                        switch intent {
                        case .hangUp: feedback.run(.hangUp, in: workspace, perform: perform)
                        case .perform(let operation): feedback.run(operation, in: workspace, perform: perform)
                        case .toggleMute, .stopExecution: break
                        }
                    })
                }
            }
            .task { await DebugHooks.preparePhoneVoice(workspace) }
    }
}

/// 单拆一个视图读通话的投影：听、说、静音换态只重算这一条，不重算输入框。
private struct PhoneCallBar: View {
    let feedback: PhoneVoiceFeedback
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let state = workspace.phoneVoiceViewState
        CueVoiceView(presentation: state.shared(rejection: feedback.rejection), detailsSource: Bindable(workspace).voiceDetails) { intent in
            switch intent {
            case .toggleMute: feedback.run(.setMuted(!state.muted), in: workspace, perform: workspace.performPhoneVoice)
            case .hangUp: feedback.run(.hangUp, in: workspace, perform: workspace.performPhoneVoice)
            case .perform(let operation): feedback.run(operation, in: workspace, perform: workspace.performPhoneVoice)
            case .stopExecution: break
            }
        }
    }
}

extension Workspace {
    /// 发起手机通话（输入框里的通话钮、提示条上的"重新接通"）。此刻就起不了的（没连上 Mac、正忙）当场说原因，不碰通话；
    /// `start` 抛出的 `VoiceIssue` 都已写进通话的阶段，由 `PhoneVoiceEndings` 带着恢复的动作说，这里不再说一遍。
    func callCue() {
        if let reason = services.voice.startUnavailableReason {
            say(reason.phoneMessage, tone: .failure)
            return
        }
        attempt {
            do { try await self.startVoiceCall() } catch is VoiceIssue {}
        }
    }

    /// 通话结束得要你知道的那一种；正常挂断、进后台、还在通话都是 nil。只由阶段与请求推出，不另存。
    var phoneVoiceEnding: PhoneVoiceEnding? {
        let voice = services.voice
        return switch voice.phase {
        case .failed(let issue): .failed(issue)
        case .ended(let reason) where reason != .hungUp && reason != .background: .failed(.ended(reason))
        case .ended: voice.requestPages.page.items.contains { $0.issue != nil } ? .unsent : nil
        default: nil
        }
    }
}

enum PhoneVoiceEnding: Equatable {
    case failed(VoiceIssue)
    /// 正常挂断，但有话没交给 Cue（原话与恢复在通话详情里）。
    case unsent
}

/// 通话结束时说一声：挂在每个窗口的提示条上（`NoticeBanner`），不论此刻在哪一页。正常挂断不说、不留字；
/// 异常结束说原因并给恢复的动作（重新接通，麦克风没授权是打开设置），回到 Cue 页去接；有话没交给 Cue 时给"查看"开通话详情。
/// 只在结束的那一下说：阶段一直停在结束，再出现不重说。
struct PhoneVoiceEndings: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Color.clear.onChange(of: workspace.phoneVoiceEnding) { _, ending in
            switch ending {
            case .failed(let issue):
                workspace.say(issue.phoneMessage, tone: .failure, action: issue.phoneRecovery.map(recovery))
            case .unsent:
                workspace.say("这次通话有话没交给 Cue", tone: .failure, action: Workspace.NoticeAction(title: String(localized: "查看")) {
                    workspace.show(.cue)
                    workspace.voiceDetails = .unanchored
                })
            case nil: break
            }
        }
    }

    private func recovery(_ action: PhoneVoiceAction) -> Workspace.NoticeAction {
        Workspace.NoticeAction(title: String(localized: action.title)) {
            if case .start = action {
                workspace.show(.cue)
                workspace.callCue()
            } else {
                _ = try await workspace.performPhoneVoice(action)
            }
        }
    }
}

@Observable private final class PhoneVoiceFeedback {
    var rejection: VoiceCommandResult.Rejection?

    /// 命令结果原样说出，被拒的另记一份给详情；不自动重发。
    func run(_ action: PhoneVoiceAction, in workspace: Workspace, perform: @escaping (PhoneVoiceAction) async throws -> VoiceCommandResult.Outcome?) {
        Task {
            do {
                if let result = try await perform(action) { report(result, in: workspace) }
            } catch let issue as VoiceIssue {
                workspace.say(issue.phoneMessage, tone: .failure)
            } catch let error as VoicePageError {
                workspace.say(error.phoneMessage, tone: .failure)
            } catch is VoiceSignalError {
                workspace.say("通话操作未确认，请检查连接后重试", tone: .failure)
            } catch {
                workspace.fail(error)
            }
        }
    }

    private func report(_ result: VoiceCommandResult.Outcome, in workspace: Workspace) {
        switch result {
        case .recorded: workspace.say("请求已记下")
        case .stopRequested: workspace.say("停止请求已提交")
        case .readbackQueued: workspace.say("已加入朗读队列")
        case .rejected(let reason):
            rejection = reason
            workspace.say(reason.phoneMessage, tone: .failure)
        }
    }
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
