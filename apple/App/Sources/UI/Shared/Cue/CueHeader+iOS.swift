#if os(iOS)
import SwiftUI

/// Cue 页页顶那一排的名牌（手机与 iPad 同一个，`floatingHeader` 摆它）：一块实底玻璃，定高，宽只看放在哪（`PlateStyle`）——
/// 窄屏铺满侧栏钮右边整行，iPad 右侧的 Cue 面板里定宽居中；左边头像占两行高（没有环，Cue 在动时右下一颗靛青的点，`CueAvatar`），
/// 右边上一行名字、下一行数字账（`CueStatusLine` 的 tally，`CueLedger`），左对齐。
/// Cue 页这一排只有它：这一页的焦点就是 Cue，不放搜索钮；不随字长短变宽：数字账随时在变，跟着变宽整颗名牌就一直在动。
/// 比圆钮高一截（两行字要的高），对话按它让出（`floatingHeader` 的 `height`）。
/// 点它从顶部长出面板（`GrowPanel`，同一块玻璃长大）：名牌原地长成名片（头像从左边连续地长大、挪到正中，名字与数字账排在它下面、居中），下面是 Cue 自己的那几样
/// （`CueNowPanel`：大脑、上下文、记忆、设置），手机上这些只有这一个入口（额度在进展页顶栏的额度环里，在做的会话在会话条上）。
/// 头像只有一个、跟着长大（`PlateLayout`），接力的落点挂在它上面。与 Mac 右栏的页头（`CueTitle`）读同一份数据（`CueWatch`）。
/// 点名牌、点面板外、在名牌上往上划都收起；点面板里的一项先收起再去那里。
/// 开面板先收起键盘：面板盖住对话的上半截，键盘弹着时放不下；打开它就是从打字转去看 Cue，草稿留在输入框里，收起面板不再弹回（同推入别的页时交出焦点）。
/// 名牌浮在对话上，展开不改对话的布局，长大的只有这一块；展开与否只在这里（不进 `CueWatch`：别处也读它）。
/// 大脑那一行要的（设置与那台 Mac 的 Agent，`observingCueBrain`）随名牌一直订阅着：面板开时才建，长出的第一帧就是真的；其余都是整个窗口已经在订阅的。
struct CueHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.headerHost) private var host
    @Environment(Workspace.self) private var workspace
    @State private var expanded = DebugHooks.preset.cuePanelOpen
    @State private var brain: AgentModelChoice?

    /// 名牌的高：两行字（名字、数字账）上下各留一截。
    nonisolated static let height: CGFloat = 56

    var body: some View {
        let style = host == .page ? PlateStyle.fill : .compact
        ZStack(alignment: .topLeading) {
            // 窄屏：开侧栏的圆钮与名牌同一排、同一条中线；名牌长开时盖住它（点面板外先收起）
            if host == .page {
                Button("侧栏", icon: .sidebar) { workspace.toggleSidebar() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .circular))
                    .frame(height: Self.height)
                    .accessibilityIdentifier("narrow-sidebar")
            }
            plate(style)
        }
    }

    private func plate(_ style: PlateStyle) -> some View {
        GrowPanel(open: $expanded, radius: Self.height / 2) {
            Button(action: toggle) { CuePlate(card: expanded, style: style) }
                .buttonStyle(.plain)
                .highPriorityGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    if expanded, drag.translation.height < -24 { toggle() }
                })
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "换模型，看它刚记下的，去记忆与设置")
        } panel: {
            CueNowPanel(brain: brain, close: toggle)
        }
        // 窄屏收着时让出左边的侧栏钮；长开时铺满整排、盖住它（`GrowPanel`）
        .padding(.leading, style.width == nil && !expanded ? FloatingHeaderLayout.slot : 0)
        .preference(key: CuePanelOpen.self, value: expanded)
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel(toggle)
    }

    private func toggle() {
        if !expanded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        $expanded.grow(reduceMotion: reduceMotion)
    }
}

/// 名牌长开着 Cue 的面板：窄屏 Cue 页据此让会话条让开（`NarrowCue`），面板盖住它、点面板外只收起。
struct CuePanelOpen: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// 名牌收着时的样子，两种只差尺寸与字号，开成名片后同一种：
/// - `fill`（窄屏 Cue 页）：铺满侧栏钮右边整行。这一屏的焦点是 Cue，头像、名字放大一档；高仍同 `compact`，对话不往下推。
/// - `compact`（iPad 右侧的 Cue 面板）：定宽，比两侧页边之间窄，又放得下"1 拍板 1 待回复 4 推进中"。
struct PlateStyle {
    /// 收着时的宽；nil 是铺满给的宽。
    let width: CGFloat?
    /// 收着时头像的直径与它离名牌左边：圆头像贴着胶囊的圆头，上下左右留白一样。
    let face: CGFloat
    let inset: CGFloat
    let nameGap: CGFloat
    let lineGap: CGFloat
    let name: Font
    let line: Font
    /// 字号跟着动态字体放大到这一档为止，再大第二行就出了定高的名牌。
    let largestType: DynamicTypeSize

    static let fill = PlateStyle(
        width: nil, face: 48, inset: (CueHeader.height - 48) / 2, nameGap: 12, lineGap: 1,
        name: .title3.weight(.bold), line: .subheadline, largestType: .xLarge)
    static let compact = PlateStyle(
        width: 244, face: 40, inset: 8, nameGap: 10, lineGap: 2,
        name: .subheadline.weight(.semibold), line: .caption, largestType: FloatingHeaderLayout.largestType)
}

/// 名牌本身：收着是定高的一块（头像在左、两行字在右），`card` 时长成名片（铺满面板的宽、头像放大到名片那一档、居中）。字号两态不变，长大的只有头像。
/// 名字与数字账只一份，开合时跟着摆法（`PlateLayout`）连续挪位，不交叉淡化：两份半透明叠在一起时字多就发花。
private struct CuePlate: View {
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
/// - 收着：定高（`CueHeader.height`），宽按 `PlateStyle`，头像贴左、竖直居中，名字与数字账在它右边上下两行、左对齐，这一组对着头像竖直居中。
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
            y: Self.lerp(CueHeader.height / 2, Self.cardTop + large, p))
        let down = Self.ease(p / Self.turn), across = Self.ease((p - Self.turn) / (1 - Self.turn))
        let beside = center.x + radius + style.nameGap
        let top = Self.lerp(center.y - words / 2, center.y + radius + Self.cardGap, down)
        let nameAt = CGPoint(x: Self.lerp(beside, center.x - name.width / 2, across), y: top)
        let lineAt = CGPoint(x: Self.lerp(beside, center.x - line.width / 2, across), y: top + name.height + style.lineGap)
        let cardHeight = Self.cardTop + 2 * large + Self.cardGap + words + Self.cardBottom
        let h = max(Self.lerp(CueHeader.height, cardHeight, p), lineAt.y + line.height + Self.cardBottom)
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
#endif
