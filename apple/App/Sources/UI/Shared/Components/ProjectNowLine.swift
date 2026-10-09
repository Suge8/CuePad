import SwiftUI

/// 项目"此刻"一行（`ProjectNow`）：Agent 的事带它的状态标（`PiStateDot`，颜色只给等你确认与出错），后面一句次要墨色，
/// 单行截断、一直占一行的高度——没有可说的也留着，卡片与行不因状态出现、消失而跳。换句子时原地淡入淡出，状态标的变化由它自己过渡。
struct ProjectNowLine: View {
    let now: ProjectNow?
    let font: Font
    var dot: CGFloat = 6
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .leading) {
            Text(verbatim: " ").font(font).hidden()
            if let now {
                HStack(spacing: 5) {
                    if let shown = now.shown { PiStateDot(shown: shown, size: dot) }
                    Text(now.text).font(font).foregroundStyle(now.needsYou ? palette.ink : palette.ink2).lineLimit(1)
                }
                .id(now.text)
                .transition(.opacity)
            }
        }
        .animation(Motion.quick, value: now?.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.map { now in now.shown.map { "\($0.presence)：\(now.text)" } ?? now.text } ?? "")
    }
}
