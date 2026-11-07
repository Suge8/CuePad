#if os(macOS)
import SwiftUI

/// Mac 的内嵌通话区：落在 Cue 栏内，主区继续看任务；固定高度，不随转写或错误长短挤动按钮。
/// 展开/收起属于宿主的呈现选择；通话收起后仍保留静音、挂断和停止执行。Esc 只收起，不挂断。
struct CueVoiceView: View {
    let presentation: CueVoicePresentation
    let expanded: Bool
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette

    // Cue 栏最窄 320pt 时仍留出约六行可阅读文字；收起只占两排控件，不盖住任务。
    static let expandedHeight: CGFloat = 480
    static let compactHeight: CGFloat = 108

    var body: some View {
        VStack(spacing: Spacing.group) {
            heading
            if expanded {
                CueVoiceTranscript(presentation: presentation, action: action)
                    .frame(maxHeight: .infinity)
            }
            controls
        }
        .padding(.vertical, Spacing.group)
        .frame(height: expanded ? Self.expandedHeight : Self.compactHeight)
        .background(palette.desk)
        .onExitCommand { if expanded { action(.collapse) } }
    }

    private var heading: some View {
        VStack(spacing: Spacing.tight) {
            if expanded {
                CueVoiceSignal(samples: presentation.samples, activity: presentation.activity, muted: presentation.muted)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .topTrailing) { expansion }
                Text(presentation.title)
                    .font(Typography.title)
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
            } else {
                HStack(spacing: Spacing.item) {
                    CueAvatar(.resting, size: .row).environment(\.pageActive, false)
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(verbatim: presentation.name).font(Typography.bodyStrong)
                        Text(presentation.title).font(Typography.meta).foregroundStyle(palette.ink2)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    expansion
                }
            }
        }
        .padding(.horizontal, Spacing.page)
    }

    private var expansion: some View {
        Button { action(expanded ? .collapse : .expand) } label: {
            if expanded { Label("收起通话", icon: .collapse) }
            else { Label("展开通话", icon: .expand) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ControlButtonStyle(kind: .icon))
        .help(expanded ? Text("收起通话") : Text("展开通话"))
    }

    private var controls: some View {
        HStack(spacing: Spacing.item) {
            Button { action(.stopExecution) } label: { Text("停止执行") }
                .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                .disabled(!presentation.canStopExecution)
                .help("停止已交给 Cue 的执行")
            Spacer(minLength: 0)
            Button { action(.toggleMute) } label: {
                if presentation.muted { Text("取消静音") }
                else { Text("静音") }
            }
            .buttonStyle(ControlButtonStyle(size: .compact))
            .disabled(!presentation.activity.isLive)
            .accessibilityValue(presentation.muted ? Text("已静音") : Text("麦克风已开启"))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button(role: .destructive) { action(.hangUp) } label: { Text("挂断") }
                .buttonStyle(ControlButtonStyle(size: .compact))
                .disabled(!presentation.activity.isLive)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Spacing.page)
    }
}

/// Cue 回复框的常驻入口；接入后与文字发送并列，由宿主决定开始通话或展开已有通话。
struct CueVoiceEntry: View {
    let inCall: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if inCall { Label("返回通话", icon: .audio) }
            else { Label("和 Cue 通话", icon: .audio) }
        }
        .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
    }
}
#endif
