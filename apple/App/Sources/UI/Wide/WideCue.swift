import SwiftUI

/// Cue 钮（宽屏）：一颗头像钮，有等你或新消息时角上带点（`CueDot`）。Cue 露着时它收起 Cue（`shown`，`Workspace.hideCue`），
/// 收着时放回（`showCue`）：放得下回到右边，放不下从窗口右缘拉出抽屉（`Workspace.cueDrawer`）。
/// Mac 只在 Cue 收着时有（窗口右上、压在最右那一块的栏头右端；露着时点 Cue 栏头最右的收起右栏，`CueTitle`，抽屉开着时也不画）；Cue 交活的光点那时落在这里（`relaySpot(cue: .entry)`）。
/// iPad 一直在会话条顶上那一排：Cue 页的名牌点了是名片面板，收起只有这一处。
struct CueButton: View {
    let fits: Bool
    var shown = false
    @Environment(Workspace.self) private var workspace

    #if os(macOS)
    /// 它压在最右那一块的栏头右端，那一块的栏头右边让出：窗边、钮宽、与 × 之间一道缝。
    static let reserve: CGFloat = Spacing.page + ControlMetrics.height + Spacing.item
    #endif

    var body: some View {
        let cue = workspace.cue
        Button {
            if shown { workspace.hideCue(fits: fits) } else { workspace.showCue() }
        } label: {
            avatar
                .overlay(alignment: .topTrailing) { CueDot().offset(x: 2, y: -2) }
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(shown ? "收起 \(cue.name)" : fits ? "放回 \(cue.name)" : "看 \(cue.name)")
        .accessibilityLabel(cue.name)
        .accessibilityValue(shown ? Text("开着") : Text("收着"))
    }

    /// Cue 露着时光点落在它的页头上（`CueSpot.header`），钮不挂入口，不然交活的光飞到钮上去
    @ViewBuilder private var avatar: some View {
        if shown { CueAvatar(workspace.cue.beat, size: .row) } else { CueAvatar(workspace.cue.beat, size: .row).relaySpot(cue: .entry) }
    }
}
