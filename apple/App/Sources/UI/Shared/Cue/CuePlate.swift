import SwiftUI

struct PlateStyle {
    let width: CGFloat?
    let height: CGFloat
    let face: CGFloat
    let inset: CGFloat
    let nameGap: CGFloat
    let lineGap: CGFloat
    let name: Font
    let line: Font
    /// 字号跟着动态字体放大到这一档为止，再大第二行就出了定高的名牌。
    let largestType: DynamicTypeSize

    #if os(iOS)
    static let fill = PlateStyle(
        width: nil, height: CueHeader.height, face: 48, inset: (CueHeader.height - 48) / 2, nameGap: 12, lineGap: 1,
        name: .title3.weight(.bold), line: .subheadline, largestType: .xLarge)
    static let compact = PlateStyle(
        width: 244, height: CueHeader.height, face: 40, inset: 8, nameGap: 10, lineGap: 2,
        name: .subheadline.weight(.semibold), line: .caption, largestType: FloatingHeaderLayout.largestType)
    #else
    static let column = PlateStyle(
        width: nil, height: 52, face: 44, inset: 4, nameGap: 10, lineGap: 1,
        name: Typography.cueCardName, line: Typography.secondary, largestType: .large)
    #endif
}

/// 名字与数字账只一份，开合时跟着摆法（`PlateLayout`）连续挪位，不交叉淡化：两份半透明叠在一起时字多就发花。
struct CuePlate: View {
    let card: Bool
    let style: PlateStyle
    /// 名牌右端另放了东西（Mac 右栏的收起钮）：字让出这么宽。
    var reserve: CGFloat = 0
    /// 名字后面一颗小箭头说它点得开（Mac；手机的名牌自己长成名片，不用）：面板开着时朝上。
    var opens: Bool?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cue = workspace.cue
        let full = CueAvatar.Size.card.side
        let side = card ? full : style.face
        PlateLayout(progress: card ? 1 : 0, style: style, reserve: reserve) {
            // 头像只按名片那一档画一次，收着时整体缩小：开合时连续地长大，点与表情不换档
            CueAvatar(cue.beat, size: .card)
                .scaleEffect(side / full)
                .frame(width: side, height: side)
                .relaySpot(cue: .header)
            HStack(spacing: Spacing.glyph) {
                Text(cue.name).font(style.name).foregroundStyle(palette.ink).lineLimit(1)
                if let opens { DisclosureChevron(open: opens) }
            }
            CueStatusLine(tally: true, font: style.line).lineLimit(1)
        }
        .dynamicTypeSize(...style.largestType)
        .contentShape(.rect)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: cue.now)
        .accessibilityElement(children: .combine)
    }
}

/// 数字账两态都按收着时那一栏的宽排（`column`）：名片里放得下全列也不换排法，开合前后是同一排字。
private struct PlateLayout: Layout {
    var progress: CGFloat
    let style: PlateStyle
    let reserve: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let trailing: CGFloat = 16
    private static let cardGap: CGFloat = 8
    private static let cardTop: CGFloat = 18
    private static let cardBottom: CGFloat = 2
    private static let turn: CGFloat = 0.5

    private struct Frame {
        var size: CGSize
        var avatar: CGPoint, radius: CGFloat
        var name: CGPoint, line: CGPoint
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func ease(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }

    private func collapsed(_ width: CGFloat?) -> CGFloat { style.width ?? width ?? 0 }

    private func column(_ width: CGFloat?) -> ProposedViewSize {
        ProposedViewSize(width: max(collapsed(width) - style.inset - Self.trailing - reserve - style.face - style.nameGap, 0), height: nil)
    }

    private func frame(width: CGFloat?, _ subviews: Subviews) -> Frame {
        let p = min(max(progress, 0), 1)
        let lines = column(width)
        let name = subviews[1].sizeThatFits(lines), line = subviews[2].sizeThatFits(lines)
        let words = name.height + style.lineGap + line.height
        let small = style.face / 2, large = CueAvatar.Size.card.side / 2
        let start = collapsed(width)
        let full = max(width ?? start, start)
        let w = Self.lerp(start, full, p)
        let radius = Self.lerp(small, large, p)
        let center = CGPoint(
            x: Self.lerp(style.inset + small, w / 2, p),
            y: Self.lerp(style.height / 2, Self.cardTop + large, p))
        let down = Self.ease(p / Self.turn), across = Self.ease((p - Self.turn) / (1 - Self.turn))
        let beside = center.x + radius + style.nameGap
        let top = Self.lerp(center.y - words / 2, center.y + radius + Self.cardGap, down)
        let nameAt = CGPoint(x: Self.lerp(beside, center.x - name.width / 2, across), y: top)
        let lineAt = CGPoint(x: Self.lerp(beside, center.x - line.width / 2, across), y: top + name.height + style.lineGap)
        let cardHeight = Self.cardTop + 2 * large + Self.cardGap + words + Self.cardBottom
        let h = max(Self.lerp(style.height, cardHeight, p), lineAt.y + line.height + Self.cardBottom)
        return Frame(size: CGSize(width: w, height: h), avatar: center, radius: radius, name: nameAt, line: lineAt)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frame(width: proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // 与量尺寸时同一个给的宽：这一刻的宽是按进度从收着的宽长向它的（`bounds` 已是长到一半的宽，不能再拿它当铺满的宽）
        let f = frame(width: proposal.width, subviews)
        let origin = CGPoint(x: bounds.midX - f.size.width / 2, y: bounds.minY)
        subviews[0].place(at: CGPoint(x: origin.x + f.avatar.x, y: origin.y + f.avatar.y), anchor: .center, proposal: .unspecified)
        let lines = column(proposal.width)
        subviews[1].place(at: CGPoint(x: origin.x + f.name.x, y: origin.y + f.name.y), anchor: .topLeading, proposal: lines)
        subviews[2].place(at: CGPoint(x: origin.x + f.line.x, y: origin.y + f.line.y), anchor: .topLeading, proposal: lines)
    }
}
