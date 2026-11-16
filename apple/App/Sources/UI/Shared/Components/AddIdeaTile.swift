import SwiftUI

/// 灵感墙永远的第一格（三端同一个），项目页记灵感的唯一入口：虚线框里一只 Cue 与"添加灵感"，整格可点。
/// 点了新建一条，等它落到墙上再从那一格打开（`ProjectWallSections`），编辑页是从新卡长出来的，返回也收回它。
/// 它说的是下一步，不是空态：没有灵感时也是这一格，不等 iCloud 对完。
struct AddIdeaTile: View {
    /// 格里那只 Cue 跟着这个项目此刻的样子换：有会话等你是举着信的，任务都做完了是举手庆祝的，平时举着一颗星。
    enum Mood: String {
        case idea = "mascot-welcome", waiting = "mascot-cue-waiting", done = "mascot-cue-done"
    }

    var mood = Mood.idea
    let action: () -> Void
    @Environment(\.noteColor) private var color
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    @ScaledMetric(relativeTo: .body) private var height = NoteTile.height
    private static let mascot: CGFloat = 56
    private static let hop: CGFloat = 4
    private static let dash = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 6])

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        Button(action: action) {
            VStack(spacing: Spacing.item) {
                Image(decorative: mood.rawValue).resizable().scaledToFit()
                    .frame(width: Self.mascot, height: Self.mascot)
                    .id(mood).transition(Motion.pop(reduceMotion: reduceMotion))
                    .offset(y: hovering && !reduceMotion ? -Self.hop : 0)
                    .readerHidden(true)
                Text("添加灵感").font(Typography.bodyStrong).foregroundStyle(palette.ink2)
            }
            .padding(Spacing.block)
            .frame(maxWidth: .infinity).frame(height: height)
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
        .animation(Motion.nudge, value: mood)
    }
}

/// 灵感墙是等高的规整网格（同 Craft、Notion 的画廊）：每格一样高，标题至多两行、摘要填满剩下的高、日期那一行贴底；带图的格图铺满上半（贴着卡边、由卡裁圆角）、不写摘要。
/// 高矮不一的瀑布流只适合图片比例差别很大的内容，文字卡排出来参差、扫读时眼睛要上下找。手机上这个高随字号放大。
enum NoteTile {
    #if os(macOS)
    static let height: CGFloat = 156
    static let thumbnail: CGFloat = 84
    #else
    static let height: CGFloat = 164
    static let thumbnail: CGFloat = 84
    #endif
    static let titleLines = 2
}

extension EnvironmentValues {
    /// 这面墙所在项目的颜色（库里存的值）：灵感卡的淡彩纸与"添加灵感"的虚线按它调（`Palette.note`）。
    @Entry var noteColor = Palette.neutralProject
}
