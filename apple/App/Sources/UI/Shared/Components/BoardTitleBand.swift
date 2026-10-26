import SwiftUI

/// 卡上标题那一带（看板上所有的卡：三端的列与手机的行同一条）：字号、折几行、占多高只在这里定，按这一带的宽与字号——
/// 宽得下 `oneLine` 个字排一行，否则两行，辅助字号下再多一行。高按行数留足：只有一行字的卡也一样高（同一列的卡一样宽，就一样高，
/// 卡多卡少、字长字短都不跳），字在里面竖直居中，多出的字截掉（字按给它的高截行，`lineLimit` 只封顶）。
/// 一个字多宽、几行多高量一把藏着的尺：满 `maxLines` 行的"国"，再给它一行的高量一行（中文的行比西文高，按它留不会截掉中文的下一行；
/// 多行的高不是一行的整倍数，按满行与一行之间的行距算）。
/// 按宽定排法用 `Layout`、一次排版里算完，不经几何读数写回状态（docs/ui.md 布局约束）。
struct BoardTitleBand<Content: View>: View {
    /// 至少多高：开头的记号见方。
    let least: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.boardRow) private var row
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        BandLayout(accessible: typeSize.isAccessibilitySize, least: least) {
            content
            Text(verbatim: BandLayout.fullRuler).hidden().accessibilityHidden(true)
        }
        .font(row ? BoardCardMetrics.rowTitle : TaskMetrics.lineFont)
        .lineLimit(BandLayout.maxLines)
    }
}

private struct BandLayout: Layout {
    let accessible: Bool
    let least: CGFloat

    static let maxLines = 3
    static let fullRuler = Array(repeating: "国", count: maxLines).joined(separator: "\n")
    /// 宽得下几个字（连开头记号与项目小图形占的位）才只排一行：Mac 常用的窗口与 iPad 横屏的列里一行写得下大多数标题，
    /// iPad 竖屏、窄窗口、iPhone 横屏的列与手机的行里写不下。
    private static let oneLine: CGFloat = 14

    /// 一个字的宽与一行、满行的高。
    struct Ruler {
        var em: CGFloat
        var line: CGFloat
        var full: CGFloat
    }

    func makeCache(subviews: Subviews) -> Ruler {
        let full = subviews[1].sizeThatFits(.unspecified), one = subviews[1].sizeThatFits(ProposedViewSize(width: nil, height: 1))
        return Ruler(em: full.width, line: one.height, full: full.height)
    }

    func updateCache(_ cache: inout Ruler, subviews: Subviews) { cache = makeCache(subviews: subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Ruler) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        return CGSize(width: width, height: height(width: width, ruler: cache))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Ruler) {
        let band = ProposedViewSize(width: bounds.width, height: height(width: bounds.width, ruler: cache))
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: band)
        // 尺按量它时的理想尺寸摆（藏着，不画），不另排一遍
        subviews[1].place(at: bounds.origin, proposal: .unspecified)
    }

    private func height(width: CGFloat, ruler: Ruler) -> CGFloat {
        let lines = (width >= ruler.em * Self.oneLine ? 1 : 2) + (accessible ? 1 : 0)
        let advance = (ruler.full - ruler.line) / CGFloat(Self.maxLines - 1)
        return max(least, (ruler.line + advance * CGFloat(lines - 1)).rounded(.up))
    }
}
