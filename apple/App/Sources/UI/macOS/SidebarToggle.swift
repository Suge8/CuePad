#if os(macOS)
import SwiftUI

/// 会话条的开合钮（⌃⌘S）：窗口最顶那一排、红绿灯右边一颗无底的图标钮（`ControlButtonStyle.icon`，圆与红绿灯一个分量：`ControlSize.compact`），
/// 悬停才浮淡底，同系统工具栏不带玻璃的项。会话条开着、藏起都不动（`Chrome.toggle`，同访达、备忘录）；放不下时它拉出、收回左缘的抽屉（`Workspace.toggleRail`）。
/// 会话条没露着时角上一颗等你的点（`railWaitingDot`，同 iPad 顶上那一排的侧栏钮）。
struct SidebarToggle: View {
    let sizes: WideMetrics
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("显示或隐藏侧栏", icon: .sidebar) { workspace.toggleRail(sizes) }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .railWaitingDot(hidden: !workspace.railShown(sizes))
            .help(Text("显示或隐藏侧栏（⌃⌘S）"))
            .padding(.leading, Chrome.toggle)
            .frame(height: Chrome.band)
    }
}
#endif
