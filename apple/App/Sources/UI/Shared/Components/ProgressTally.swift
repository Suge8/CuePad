import SwiftUI

/// 侧栏进展那一行行尾（Mac、iPad）："N 推进中 · M 等你"，数读 Cue 那一份计数（`CueNow.advancing`、`needsYou`，同名牌与看板列头）；
/// 等你是赭黄、加粗一档，都是零时不写。行里放不下（英文比中文宽）时让给去处名：只写数"N · M"，颜色仍分得出哪个是等你，读屏照念全句。
struct ProgressTally: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let advancing = workspace.cue.now.advancing, waiting = workspace.cue.now.needsYou
        if advancing > 0 || waiting > 0 {
            ViewThatFits(in: .horizontal) {
                counts(advancing: Text("\(advancing) 推进中"), waiting: Text("\(waiting) 等你"))
                counts(advancing: Text(advancing, format: .number), waiting: Text(waiting, format: .number))
            }
            .monospacedDigit().lineLimit(1)
            .animation(nil, value: [advancing, waiting])
            .handOff(id: [advancing > 0 ? "advancing" : nil, waiting > 0 ? "waiting" : nil].compactMap { $0 })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Dotted(advancing > 0 ? String(localized: "\(advancing) 推进中") : nil, waiting > 0 ? String(localized: "\(waiting) 等你") : nil).spoken)
        }
    }

    private func counts(advancing: Text, waiting: Text) -> some View {
        let shows = (advancing: workspace.cue.now.advancing > 0, waiting: workspace.cue.now.needsYou > 0)
        return HStack(spacing: 4) {
            if shows.advancing { advancing.foregroundStyle(palette.ink2).rollingCount(workspace.cue.now.advancing) }
            if shows.advancing, shows.waiting { Dot().foregroundStyle(palette.ink2) }
            if shows.waiting { waiting.foregroundStyle(palette.waiting).fontWeight(.semibold).rollingCount(workspace.cue.now.needsYou) }
        }
        .fixedSize()
    }
}
