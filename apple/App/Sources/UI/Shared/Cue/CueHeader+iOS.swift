#if os(iOS)
import SwiftUI

/// Cue 页页顶那一排中间的名牌（手机、iPad 与 iPad 右侧的 Cue 面板同一个，`floatingHeader` 摆它）：一块实底玻璃，定宽定高、居中——
/// 左边头像占两行高（没有环，Cue 在动时右下一颗靛青的点，`CueAvatar`），右边上一行名字、下一行数字账（`CueStatusLine` 的 tally，`CueLedger`），左对齐。
/// Cue 页这一排只有它：这一页的焦点就是 Cue，不放搜索钮；不随字长短变宽：数字账随时在变，跟着变宽整颗名牌就一直在动。
/// 比圆钮高一截（两行字要的高），对话按它让出（`floatingHeader` 的 `height`）。
/// 点它从顶部长出面板（`GrowPanel`，同一块玻璃长大）：名牌原地长成名片（头像从左边连续地长大、挪到正中，名字与数字账排在它下面、居中），下面是 Cue 自己的那几样
/// （`CueNowPanel`：大脑、上下文、记忆、设置），手机上这些只有这一个入口（额度在进展页顶栏的额度环里，在做的会话在进展页的会话段）。
/// 头像只有一个、跟着长大（`PlateLayout`），接力的落点挂在它上面。与 Mac 侧栏的 Cue 名片是同一套件、同一份数据（`CueWatch`）。
/// 点名牌、点面板外、在名牌上往上划都收起；点面板里的一项先收起再去那里。
/// 开面板先收起键盘：面板盖住对话的上半截，键盘弹着时放不下；打开它就是从打字转去看 Cue，草稿留在输入框里，收起面板不再弹回（同推入别的页时交出焦点）。
/// 名牌浮在对话上，展开不改对话的布局，长大的只有这一块；展开与否只在这里（不进 `CueWatch`：侧栏也读它）。
/// 放在 iPad 的系统导航栏里时（`HeaderHost.navigationBar`）名牌不长，面板从它弹出（`GrowPanel`），名片的那一头不出现。
/// 大脑那一行要的（设置与那台 Mac 的 Agent，`observingCueBrain`）随名牌一直订阅着：面板开时才建，长出的第一帧就是真的；其余都是整个窗口已经在订阅的。
struct CueHeader: View {
    @Environment(\.headerHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.cuePanelOpen
    @State private var brain: AgentModelChoice?

    /// 名牌的高：两行字（名字、数字账）上下各留一截。
    nonisolated static let height: CGFloat = 56
    /// 名牌的宽：比两侧页边之间窄，又放得下"1 拍板 1 待回复 4 推进中"。
    nonisolated static let width: CGFloat = 244
    /// 收着时头像的直径：两行字的高。
    nonisolated static let face: CGFloat = 40

    var body: some View {
        GrowPanel(open: $expanded, radius: Self.height / 2) {
            Button(action: toggle) { CuePlate(card: expanded && host != .navigationBar) }
                .buttonStyle(.plain)
                .highPriorityGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    if expanded, drag.translation.height < -24 { toggle() }
                })
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "换模型，看它刚记下的，去记忆与设置")
        } panel: {
            CueNowPanel(brain: brain, close: toggle)
        }
        .observingCueBrain(into: $brain)
        .debugExposesCuePanel(toggle)
    }

    private func toggle() {
        if !expanded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        $expanded.grow(reduceMotion: reduceMotion)
    }
}

/// 名牌本身：收着是定宽定高的一块（头像在左、两行字在右），`card` 时长成名片（铺满面板的宽、头像放大到名片那一档、居中）。字号两态不变，长大的只有头像。
/// 名字与数字账只一份，开合时跟着摆法（`PlateLayout`）连续挪位，不交叉淡化：两份半透明叠在一起时字多就发花。
private struct CuePlate: View {
    let card: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cue = workspace.cue
        let full = CueAvatar.Size.card.side
        let side = card ? full : CueHeader.face
        PlateLayout(progress: card ? 1 : 0) {
            // 头像只按名片那一档画一次，收着时整体缩小：开合时连续地长大，点与表情不换档
            CueAvatar(cue.now, mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), size: .card)
                .scaleEffect(side / full)
                .frame(width: side, height: side)
                .relaySpot(cue: .header)
            Text(cue.name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
            CueStatusLine(tally: true, font: .caption).lineLimit(1)
        }
        // 收着是定高的两行：字号跟着动态字体放大到这一档为止，再大第二行就被裁掉
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .contentShape(.rect)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: cue.now)
        .accessibilityElement(children: .combine)
    }
}

/// 名牌里头像、名字、数字账的摆法，收着（`progress` 0）到名片（1）之间每一帧都按开合进度重排（`animatableData`），三样都只有一份：
/// - 收着：定宽定高（`CueHeader.width`×`height`），头像贴左、竖直居中，名字与数字账在它右边上下两行、左对齐，这一组对着头像竖直居中。
/// - 名片：铺满给的宽，头像在上、居中，名字、数字账依次在它下面、各自居中。
/// - 开合中：头像从左连续长到正中；字绕开长大的头像走——前半程贴着头像右边往下挪到头像下沿之下，后半程在头像下面横移到居中。
///   名牌的宽高跟着进度长，高总是让得下字（不比"字的下沿加底边"矮），任何一帧字都不出玻璃。
/// 数字账两态都按收着时那一栏的宽排（`lineWidth`）：名片里放得下全列也不换排法，开合前后是同一排字。
/// 子视图依次是头像、名字、数字账。
private struct PlateLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// 收着时头像离名牌左边：圆头像贴着胶囊的圆头，左右留白看着一样。
    private static let inset: CGFloat = 8
    private static let trailing: CGFloat = 16
    private static let nameGap: CGFloat = 10
    private static let lineGap: CGFloat = 2
    private static let cardGap: CGFloat = 8
    /// 名片时头像离顶、字离底。
    private static let cardTop: CGFloat = 18
    private static let cardBottom: CGFloat = 2
    /// 收着时右边那一栏的宽：名牌宽减去两侧留白、头像与它到字的距离。
    private static let lineWidth = CueHeader.width - inset - trailing - CueHeader.face - nameGap
    /// 前半程往下、后半程横移的分界。
    private static let turn: CGFloat = 0.5

    private struct Frame {
        var size: CGSize
        var avatar: CGPoint, radius: CGFloat
        var name: CGPoint, line: CGPoint
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private static func ease(_ t: CGFloat) -> CGFloat { let t = min(max(t, 0), 1); return t * t * (3 - 2 * t) }

    /// 这一刻三样各在哪（名字、数字账给左上角）、整块多大；`width` 是名片时铺满的宽。
    private func frame(width: CGFloat?, _ subviews: Subviews) -> Frame {
        let p = min(max(progress, 0), 1)
        let column = ProposedViewSize(width: Self.lineWidth, height: nil)
        let name = subviews[1].sizeThatFits(column), line = subviews[2].sizeThatFits(column)
        let words = name.height + Self.lineGap + line.height
        let small = CueHeader.face / 2, large = CueAvatar.Size.card.side / 2
        let full = max(width ?? CueHeader.width, CueHeader.width)
        let w = Self.lerp(CueHeader.width, full, p)
        let radius = Self.lerp(small, large, p)
        let center = CGPoint(
            x: Self.lerp(Self.inset + small, w / 2, p),
            y: Self.lerp(CueHeader.height / 2, Self.cardTop + large, p))
        let down = Self.ease(p / Self.turn), across = Self.ease((p - Self.turn) / (1 - Self.turn))
        let beside = center.x + radius + Self.nameGap
        let top = Self.lerp(center.y - words / 2, center.y + radius + Self.cardGap, down)
        let nameAt = CGPoint(x: Self.lerp(beside, center.x - name.width / 2, across), y: top)
        let lineAt = CGPoint(x: Self.lerp(beside, center.x - line.width / 2, across), y: top + name.height + Self.lineGap)
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
        let column = ProposedViewSize(width: Self.lineWidth, height: nil)
        subviews[1].place(at: CGPoint(x: origin.x + f.name.x, y: origin.y + f.name.y), anchor: .topLeading, proposal: column)
        subviews[2].place(at: CGPoint(x: origin.x + f.line.x, y: origin.y + f.line.y), anchor: .topLeading, proposal: column)
    }
}
#endif
