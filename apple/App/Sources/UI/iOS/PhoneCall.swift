#if os(iOS)
import SwiftUI
import UIKit

/// 通话中"对 Cue 说"两颗圆钮之间的那一段（`CueComposer` 让出文字那一栏，`Composer.yielded`；两颗圆钮自己原地换成静音与挂断），与它的通话详情。
/// 这一段一直挂着、只按在不在通话淡入淡出：接通又马上挂断时从此刻的透明度接着走，不重建、不闪；声纹在不在通话时收成正中一点，接通时从那一点长开。
/// 只读投影（`voiceViewState`），动作经 `runVoice`。
struct PhoneCall: ViewModifier {
    let active: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var feedback = VoiceFeedback()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                // 与输入框一行时同高，左右让出两颗圆钮：居中按整条输入框算，两颗钮在不在都不挪它
                PhoneCallStatus(active: active, rejection: feedback.rejection)
                    .padding(.horizontal, ComposerMetrics.slot)
                    .frame(height: ComposerMetrics.lineSlot(line: ComposerField.lineHeight(typeSize)))
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .readerHidden(!active)
                    // 进来等字先走（`Composer.yielded` 同一拍），走时先走、字再回来
                    .animation(active ? Motion.fade.delay(Motion.Fade.yield) : Motion.yield, value: active)
            }
            .panel(isPresented: Binding { workspace.voiceDetails != nil } set: { if !$0 { workspace.voiceDetails = nil } },
                   style: .bubble(workspace.voiceDetails ?? .unanchored, width: .fixed(360))) {
                VoiceHost { state in
                    CueVoiceDetails(presentation: { state.presentation(rejection: feedback.rejection) }) { action in
                        workspace.runVoice(action) { feedback.rejection = $0 }
                    }
                }
            }
            .task { await DebugHooks.preparePhoneVoice(workspace) }
    }
}

/// 声纹与状态，点它看通话详情。单拆一个视图读通话的投影：听、说换态只重算这一段，不重算输入框。
/// 状态字按最长的那一种留宽、整段在输入框正中：听、说、静音、连接、结束换字时声纹与字都不挪，换的字原地淡换。
/// 不在通话时（正淡走）写"正在结束…"：结束的那一下不再冒出"通话已结束"。
private struct PhoneCallStatus: View {
    let active: Bool
    let rejection: VoiceCommandResult.Rejection?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let titles: [LocalizedStringResource] = [
        CueVoiceActivity.connecting.title, CueVoiceActivity.listening.title, CueVoiceActivity.processing.title,
        CueVoiceActivity.speaking.title, CueVoiceActivity.closing.title, "麦克风已静音",
    ]

    var body: some View {
        let presentation = workspace.voiceViewState.presentation(rejection: rejection)
        let title = active ? presentation.title : CueVoiceActivity.closing.title
        CueVoiceDetailButton(source: Bindable(workspace).voiceDetails) {
            HStack(spacing: Spacing.item) {
                CueVoiceSignal(presentation: presentation, seed: !active)
                ZStack(alignment: .leading) {
                    ForEach(Self.titles, id: \.key) { Text($0).hidden() }
                    Text(title)
                        .foregroundStyle(palette.ink2)
                        .overlay(alignment: .trailing) {
                            if presentation.needsAttention {
                                Image(.failure).foregroundStyle(palette.failure)
                                    .alignmentGuide(.trailing) { $0[.leading] - Spacing.glyph }
                                    .transition(Motion.pop(reduceMotion: reduceMotion))
                            }
                        }
                        .animation(Motion.fade, value: presentation.needsAttention)
                        .id(title.key)
                        .transition(swap)
                }
                .animation(Motion.fade, value: title.key)
                .font(Typography.body).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .disabled(!presentation.hasDetails)
        .accessibilityLabel(Text(title))
        .accessibilityValue(presentation.needsAttention ? Text("有问题") : Text(verbatim: ""))
        .accessibilityHint(Text("通话详情"))
        // 只在开着时撤：写一遍同样的 nil 也会让读它的视图（详情面板的开合）全部重算，正压在挂断那一帧上
        .onChange(of: presentation.hasDetails) { _, available in
            if !available, workspace.voiceDetails != nil { workspace.voiceDetails = nil }
        }
    }

    /// 换字：旧的先走完（`yield`），新的从下面半行浮上来（减弱动态效果时只淡）：同一处不叠两行字，听、说来回换也读得出是"下一句"。
    private var swap: AnyTransition {
        let arrive: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Self.rise))
        return .asymmetric(insertion: arrive.animation(Motion.fade.delay(Motion.Fade.yield)), removal: .opacity.animation(Motion.yield))
    }

    private static let rise: CGFloat = 4
}

extension Workspace {
    /// 发起手机通话（输入框里的通话钮、提示条上的"重新接通"）。此刻就起不了的（没连上 Mac、正忙）当场说原因，不碰通话；
    /// `start` 抛出的 `VoiceIssue` 都已写进通话的阶段，由 `PhoneVoiceEndings` 带着恢复的动作说，这里不再说一遍。
    func callCue() {
        if let reason = voiceStartBlock {
            say(reason.message, tone: .failure)
            return
        }
        attempt {
            do { try await self.startVoiceCall() } catch is VoiceIssue {}
        }
    }

    func startVoiceCall() async throws { try await services.voice.start() }

    /// 通话结束得要你知道的那一种；正常挂断、还在通话都是 nil。只由阶段与请求推出，不另存。
    var phoneVoiceEnding: PhoneVoiceEnding? {
        let voice = services.voice
        return switch voice.phase {
        case .failed(let issue): .failed(issue)
        case .ended(let reason) where reason != .hungUp: .failed(.ended(reason))
        case .ended: voice.projection?.requests.contains { $0.issue != nil } == true ? .unsent : nil
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
                workspace.say(issue.message, tone: .failure, action: issue.recovery.map(recovery))
            case .unsent:
                workspace.say("这次通话有话没交给 Cue", tone: .failure, action: Workspace.NoticeAction(title: String(localized: "查看")) { workspace in
                    workspace.show(.cue)
                    workspace.voiceDetails = .unanchored
                })
            case nil: break
            }
        }
    }

    private func recovery(_ action: VoiceAction) -> Workspace.NoticeAction {
        Workspace.NoticeAction(title: String(localized: action.title)) { workspace in
            if case .start = action {
                workspace.show(.cue)
                workspace.callCue()
            } else {
                try await workspace.performVoice(action)
            }
        }
    }
}
#endif
