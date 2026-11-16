import SwiftUI

/// 灵感墙永远的第一格（三端同一个），项目页记灵感的唯一入口：虚线框里一只 Cue 与"添加灵感"，整格可点。
/// 点了新建一条，等它落到墙上再从那一格打开（`ProjectWallSections`），编辑页是从新卡长出来的，返回也收回它。
/// 它说的是下一步，不是空态：没有灵感时也是这一格，不等 iCloud 对完。
struct AddIdeaTile: View {
    let action: () -> Void
    @Environment(\.noteColor) private var color
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private static let mascot: CGFloat = 56
    /// 与一张两三行字的灵感卡差不多高：墙上只有它时不是一条扁的。
    private static let minHeight: CGFloat = 132
    private static let hop: CGFloat = 4
    private static let dash = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6])

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        Button(action: action) {
            VStack(spacing: Spacing.item) {
                Image(decorative: Mascot.welcome.rawValue).resizable().scaledToFit()
                    .frame(width: Self.mascot, height: Self.mascot)
                    .offset(y: hovering && !reduceMotion ? -Self.hop : 0)
                    .readerHidden(true)
                Text("添加灵感").font(Typography.bodyStrong).foregroundStyle(palette.ink2)
            }
            .padding(Spacing.block)
            .frame(maxWidth: .infinity, minHeight: Self.minHeight)
            .background { if hovering { shape.fill(palette.noteHint(color)).transition(.opacity) } }
            .overlay { shape.strokeBorder(palette.noteEdge(color), style: Self.dash) }
            .contentShape(shape)
        }
        .buttonStyle(PressStyle(.card))
        .onHover { hovering = $0 }
        #if os(macOS)
        .presetHover($hovering)
        .help("添加灵感（⌘N）")
        #endif
        .animation(Motion.nudge, value: hovering)
    }
}

extension EnvironmentValues {
    /// 这面墙所在项目的颜色（库里存的值）：灵感卡的淡彩纸与"添加灵感"的虚线按它调（`Palette.note`）。
    @Entry var noteColor = Palette.neutralProject
}
