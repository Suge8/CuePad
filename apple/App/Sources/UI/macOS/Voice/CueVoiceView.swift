#if os(macOS)
import SwiftUI

/// Mac 的内嵌通话区：总高固定，底部控制不随转写或错误长短挪动。
/// 阅读由用户选择，舞台让出空间后不会因新回复或换轮次自行展开；收起、回来保留阅读位置。
/// 开合只改呈现，Esc 只收起。挂断只结束通话，执行与真实文字仍由宿主投影。
/// 请求失败不代表通话结束：通话中的恢复入口在错误区（收起时在标题区），不替换静音和挂断。
struct CueVoiceView: View {
    let presentation: CueVoicePresentation
    let expanded: Bool
    let action: (CueVoiceAction) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reading = false

    static let expandedHeight: CGFloat = 528
    static let compactHeight: CGFloat = 144
    private static let controlsHeight = ControlSize.compact.height * 2 + Spacing.item
    private static let foldedHeight: CGFloat = 48
    private static let foldedWidth: CGFloat = 64
    private static let headingHeight: CGFloat = 240
    // 标题先让开角色的移动路径，另一份在落位后出现，途中不叠两份字。
    private static let stageTitleEnd: CGFloat = 0.25
    private static let compactTitleStart: CGFloat = 0.9
    private var folded: Bool { !expanded || reading }

    var body: some View {
        CueVoiceFold(fold: folded ? 1 : 0, reveal: expanded ? 1 : 0) { fold, reveal in
            let height = Self.compactHeight + (Self.expandedHeight - Self.compactHeight) * reveal
            let head = Self.headingHeight + (Self.foldedHeight - Self.headingHeight) * fold
            let readingHeight = max(0, height - head - Spacing.item - Spacing.group * (2 + reveal) - Self.controlsHeight)
            VStack(spacing: 0) {
                heading(fold: fold, height: head).padding(.bottom, Spacing.item)
                CueVoiceTranscript(presentation: presentation, action: action)
                    .frame(height: readingHeight)
                    .clipped()
                    .opacity(reveal)
                    .allowsHitTesting(expanded)
                    .accessibilityHidden(!expanded)
                    .padding(.bottom, Spacing.group * reveal)
                controls
            }
            .padding(.vertical, Spacing.group)
            .frame(height: height)
            .background(palette.desk)
        }
        .onExitCommand { if expanded { action(.collapse) } }
        .animation(Motion.spatial(Motion.glide, reduceMotion: reduceMotion), value: folded)
        .animation(Motion.spatial(Motion.glide, reduceMotion: reduceMotion), value: expanded)
    }

    private func heading(fold: CGFloat, height: CGFloat) -> some View {
        let stageHeight = CueVoiceSignal.size.height + (Self.foldedHeight - CueVoiceSignal.size.height) * fold
        return GeometryReader { box in
            ZStack(alignment: .topLeading) {
                CueVoiceSignal(samples: presentation.samples, activity: presentation.activity, muted: presentation.muted)
                    .scaleEffect(stageHeight / CueVoiceSignal.size.height)
                    .position(x: box.size.width / 2 + (Self.foldedWidth / 2 - box.size.width / 2) * fold, y: stageHeight / 2)
                    .transformEnvironment(\.pageActive) { $0 = $0 && !folded }
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    if !expanded, presentation.activity.isLive, let issue = presentation.issue {
                        Text(issue.message).font(Typography.bodyStrong).foregroundStyle(palette.failure)
                    } else {
                        Text(verbatim: presentation.name).font(Typography.bodyStrong)
                    }
                    Text(presentation.title).font(Typography.meta).foregroundStyle(palette.ink2)
                }
                .lineLimit(1)
                .padding(.horizontal, Self.foldedWidth)
                .padding(.top, Spacing.tight)
                .opacity(max(0, (fold - Self.compactTitleStart) / (1 - Self.compactTitleStart)))
                .accessibilityHidden(!folded)
                Text(presentation.title)
                    .font(Typography.title).foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .offset(y: height - ControlSize.compact.height)
                    .opacity(max(0, 1 - fold / Self.stageTitleEnd))
                    .accessibilityHidden(folded)
                HStack(spacing: Spacing.tight) {
                    Spacer(minLength: 0)
                    if !expanded, presentation.activity.isLive, let issue = presentation.issue {
                        Button { action(.recover) } label: { Label(issue.recovery, icon: .retry) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(ControlButtonStyle(kind: .icon))
                            .help(Text(issue.recovery))
                    } else {
                        readingToggle.keepsPlace(shown: expanded)
                    }
                    expansion
                }
            }
        }
        .frame(height: height)
        .padding(.horizontal, Spacing.page)
        .background(palette.desk)
        .zIndex(1)
    }

    private var readingToggle: some View {
        Button {
            reading.toggle()
        } label: {
            if reading { Label("查看通话舞台", icon: .audio) }
            else { Label("阅读通话文字", icon: .readFile) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ControlButtonStyle(kind: .icon))
        .help(reading ? Text("查看通话舞台") : Text("阅读通话文字"))
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
        VStack(alignment: .leading, spacing: Spacing.item) {
            Button { action(.stopExecution) } label: { Label("停止执行", icon: .stop) }
                .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                .disabled(!presentation.canStopExecution)
                .help("停止已交给 Cue 的执行")
            HStack(spacing: Spacing.item) {
                if presentation.activity.isLive {
                    Button { action(.toggleMute) } label: {
                        if presentation.muted { Text("麦克风关") }
                        else { Text("麦克风开") }
                    }
                    .buttonStyle(ControlButtonStyle(size: .compact))
                    .accessibilityLabel(presentation.muted ? Text("开启麦克风") : Text("关闭麦克风"))
                    .accessibilityValue(presentation.muted ? Text("麦克风已静音") : Text("麦克风已开启"))
                    .help(presentation.muted ? Text("开启麦克风") : Text("关闭麦克风"))
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                }
                Spacer(minLength: 0)
                if let issue = presentation.issue, !presentation.activity.isLive {
                    Button { action(.recover) } label: { Text(issue.recovery).fixedSize() }
                        .buttonStyle(ControlButtonStyle(size: .compact))
                } else if presentation.activity == .ended {
                    Button { action(.start) } label: { Text("再次通话") }
                        .buttonStyle(ControlButtonStyle(size: .compact))
                } else {
                    Button(role: .destructive) { action(.hangUp) } label: { Text("挂断") }
                        .buttonStyle(ControlButtonStyle(size: .compact))
                }
            }
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
/// 一次开合只插值这一对进度：舞台、标题交接、正文边界与外框同一帧到同一位置。
/// 子视图不各自再插值，避免 AppKit 滚动内容先到终点、SwiftUI 标题还在旧位置时互相遮挡。
private struct CueVoiceFold<Content: View>: View, Animatable {
    var fold: CGFloat
    var reveal: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(fold, reveal) }
        set { (fold, reveal) = (newValue.first, newValue.second) }
    }

    var body: some View {
        content(fold, reveal).transaction { $0.animation = nil }
    }
}
#endif
