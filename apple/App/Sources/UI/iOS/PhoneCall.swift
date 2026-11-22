#if os(iOS)
import SwiftUI
import UIKit

struct PhoneCall: ViewModifier {
    let active: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var feedback = VoiceFeedback()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                PhoneCallStatus(active: active, rejection: feedback.rejection)
                    .padding(.horizontal, ComposerMetrics.slot)
                    .frame(height: ComposerMetrics.lineSlot(line: ComposerField.lineHeight(typeSize)))
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .readerHidden(!active)
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

    private var swap: AnyTransition {
        let arrive: AnyTransition = reduceMotion ? .opacity : .opacity.combined(with: .offset(y: Self.rise))
        return .asymmetric(insertion: arrive.animation(Motion.fade.delay(Motion.Fade.yield)), removal: .opacity.animation(Motion.yield))
    }

    private static let rise: CGFloat = 4
}

extension Workspace {
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
    case unsent
}

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
