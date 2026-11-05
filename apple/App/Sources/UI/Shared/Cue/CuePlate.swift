import SwiftUI

/// Cue 的名牌，三端同一个：定高的一块，头像占两行、右边上一行名字下一行数字账；玻璃由放它的地方垫（手机与 iPad 是长成面板的 `GrowPanel`，
/// Mac 是栏头 `CueTitle`）。几种只差尺寸与字号，开成名片后同一种（名片只在手机与 iPad，Mac 的面板是气泡）：
/// - `fill`（窄屏 Cue 页）：铺满侧栏钮右边整行。这一屏的焦点是 Cue，头像、名字放大一档；高仍同 `compact`，对话不往下推。
/// - `compact`（iPad 右侧的 Cue 面板）：定宽，比两侧页边之间窄，又放得下"1 拍板 1 待回复 4 推进中"。
/// - `column`（Mac 右边 Cue 那一栏的栏头）：铺满收起钮左边，比例同 `compact`（头像约高的七成、四周留白一样），
///   高要放进窗口最顶那一排（`Chrome.band`），比那一排的圆钮高一截：两行字要的高。
struct PlateStyle {
    /// 收着时的宽；nil 是铺满给的宽。
    let width: CGFloat?
    /// 收着时的高。
    let height: CGFloat
    /// 收着时头像的直径与它离名牌左边：圆头像贴着胶囊的圆头，上下左右留白一样。
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
        width: nil, height: 44, face: CueAvatar.Size.row.side, inset: 6, nameGap: 10, lineGap: 1,
        name: Typography.toolbarTitle, line: Typography.toolbarSubtitle, largestType: .large)
    #endif
}

/// 名牌本身：收着是定高的一块（头像在左、两行字在右），`card` 时长成名片（铺满面板的宽、头像放大到名片那一档、居中）。字号两态不变，长大的只有头像。
/// 名字与数字账只一份，开合时跟着摆法（`PlateLayout`）连续挪位，不交叉淡化：两份半透明叠在一起时字多就发花。
struct CuePlate: View {
    let card: Bool
    let style: PlateStyle
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cue = workspace.cue
        let full = CueAvatar.Size.card.side
        let side = card ? full : style.face
        PlateLayout(progress: card ? 1 : 0, style: style) {
            // 头像只按名片那一档画一次，收着时整体缩小：开合时连续地长大，点与表情不换档
            CueAvatar(cue.beat, size: .card)
                .scaleEffect(side / full)
                .frame(width: side, height: side)
                .relaySpot(cue: .header)
            Text(cue.name).font(style.name).foregroundStyle(palette.ink).lineLimit(1)
            CueStatusLine(tally: true, font: style.line).lineLimit(1)
        }
        .dynamicTypeSize(...style.largestType)
        .contentShape(.rect)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: cue.now)
        .accessibilityElement(children: .combine)
    }
}

/// 名牌里头像、名字、数字账的摆法，收着（`progress` 0）到名片（1）之间每一帧都按开合进度重排（`animatableData`），三样都只有一份：
/// - 收着：定高（`PlateStyle.height`），宽按 `PlateStyle`，头像贴左、竖直居中，名字与数字账在它右边上下两行、左对齐，这一组对着头像竖直居中。
/// - 名片：铺满给的宽，头像在上、居中，名字、数字账依次在它下面、各自居中。
/// - 开合中：头像从左连续长到正中；字绕开长大的头像走——前半程贴着头像右边往下挪到头像下沿之下，后半程在头像下面横移到居中。
///   名牌的宽高跟着进度长，高总是让得下字（不比"字的下沿加底边"矮），任何一帧字都不出玻璃。
/// 数字账两态都按收着时那一栏的宽排（`column`）：名片里放得下全列也不换排法，开合前后是同一排字。
/// 子视图依次是头像、名字、数字账。
private struct PlateLayout: Layout {
    var progress: CGFloat
    let style: PlateStyle

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let trailing: CGFloat = 16
    private static let cardGap: CGFloat = 8
    /// 名片时头像离顶、字离底。
    private static let cardTop: CGFloat = 18
    private static let cardBottom: CGFloat = 2
    /// 前半程往下、后半程横移的分界。
    private static let turn: CGFloat = 0.5

    private struct Frame {
        var size: CGSize
        var avatar: CGPoint, radius: CGFloat
        var name: CGPoint, line: CGPoint
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func ease(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }

    /// 收着时多宽：定宽的按它，铺满的按给的宽。
    private func collapsed(_ width: CGFloat?) -> CGFloat { style.width ?? width ?? 0 }

    /// 收着时右边那一栏的宽：名牌宽减去两侧留白、头像与它到字的距离。
    private func column(_ width: CGFloat?) -> ProposedViewSize {
        ProposedViewSize(width: max(collapsed(width) - style.inset - Self.trailing - style.face - style.nameGap, 0), height: nil)
    }

    /// 这一刻三样各在哪（名字、数字账给左上角）、整块多大；`width` 是名片时铺满的宽。
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
