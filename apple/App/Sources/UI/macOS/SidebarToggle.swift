#if os(macOS)
import SwiftUI

/// 会话条的开合钮（⌃⌘S）：窗口最顶那一排、红绿灯右边一颗无底的图标钮（`ControlButtonStyle.icon`，圆与红绿灯一个分量：`ControlSize.compact`），
/// 悬停才浮淡底，同系统工具栏不带玻璃的项。会话条开着、藏起都不动（`Chrome.toggle`，同访达、备忘录）；放不下时它拉出、收回左缘的抽屉（`Workspace.toggleRail`）。
/// 会话条藏起时角上一颗点说有没有在等你：有要拍板的是赭黄，只有待回复的是墨色（数只读 `CueNow.Tally`，同 Cue 的名牌与 App 图标的角标，不另算）；开着时等你那一组就在眼前，不画。
struct SidebarToggle: View {
    let sizes: WideMetrics
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tally = workspace.cue.now.tally
        let dot: Color? = workspace.railShown(sizes) ? nil : tally.asks > 0 ? palette.waiting : tally.reply > 0 ? palette.ink : nil
        Button("显示或隐藏侧栏", icon: .sidebar) { workspace.toggleRail(sizes) }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .overlay(alignment: .topTrailing) {
                if let dot { StatusDot(color: dot, rim: palette.desk).offset(x: Self.dotShift, y: -Self.dotShift).transition(Motion.pop(reduceMotion: reduceMotion)) }
            }
            .animation(Motion.fade, value: dot)
            .help(Text("显示或隐藏侧栏（⌃⌘S）"))
            .accessibilityValue(dot == nil ? Text("") : Text("等你 \(tally.needsYou)"))
            .padding(.leading, Chrome.toggle)
            .frame(height: Chrome.band)
    }

    /// 点压在圆的右上角外沿上（圆心约在圆框的内切点）。
    private static let dotShift: CGFloat = Spacing.hair
}

#endif
