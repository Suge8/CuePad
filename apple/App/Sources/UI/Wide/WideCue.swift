import SwiftUI

/// 收起的 Cue（宽屏）：一颗头像钮（Mac 在窗口右上、压在最右那一块的栏头右端；iPad 在会话条顶上那一排，不压页自己画的页顶），有等你或新消息时角上带点（`CueDot`）。Cue 交活的光点落在这里（`relaySpot(cue: .entry)`）。
/// 是用户收起的，点了放回右边；窗口放不下时点了从右边浮出、盖在主区上，再点收回（`Workspace.cueFloats`）。
struct CueButton: View {
    let fits: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    #if os(macOS)
    /// 它压在最右那一块的栏头右端，那一块的栏头右边让出：窗边、钮宽、与 × 之间一道缝。
    static let reserve: CGFloat = MainColumn.edge + ControlMetrics.height + Spacing.toolbarGap
    #endif

    var body: some View {
        let cue = workspace.cue
        Button {
            if fits { services.settings.cueOpen = true } else { workspace.cueFloats.toggle() }
        } label: {
            CueAvatar(cue.beat, size: .row)
                .relaySpot(cue: .entry)
                .overlay(alignment: .topTrailing) { CueDot().offset(x: 2, y: -2) }
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(fits ? "放回 \(cue.name)" : "看 \(cue.name)")
        .accessibilityLabel(cue.name)
    }
}
