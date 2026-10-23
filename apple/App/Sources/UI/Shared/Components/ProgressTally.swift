import SwiftUI

/// 侧栏进展那一行行尾（Mac、iPad）："N 推进中 · M 等你"，数读 Cue 那一份计数（`CueWatch.advancing`、`waiting`，同 Cue 那一行与看板列头）；
/// 等你是赭黄、加粗一档，都是零时不写。
struct ProgressTally: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let advancing = workspace.cue.advancing, waiting = workspace.cue.waiting
        HStack(spacing: 4) {
            if advancing > 0 { Text("\(advancing) 推进中").foregroundStyle(palette.ink2) }
            if advancing > 0, waiting > 0 { Dot().foregroundStyle(palette.ink2) }
            if waiting > 0 { Text("\(waiting) 等你").foregroundStyle(palette.waiting).fontWeight(.semibold) }
        }
        .monospacedDigit().lineLimit(1).fixedSize()
        .contentTransition(.numericText())
        .animation(HandOff.quick, value: advancing)
        .animation(HandOff.quick, value: waiting)
        .accessibilityElement(children: .combine)
    }
}
