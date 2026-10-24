#if os(iOS)
import SwiftUI

/// Cue 页页顶那一排中间的名牌（手机、iPad 与 iPad 右侧的 Cue 面板同一个，`floatingHeader` 摆它）：一块实底玻璃，定宽定高、居中——
/// 上一行头像接名字，下一行 Cue 此刻（珠子接一句，`CueStatusLine`），两行各自居中。Cue 页这一排只有它：这一页的焦点就是 Cue，不放搜索钮；
/// 不随字长短变宽：那一行几秒换一句，跟着变宽整颗名牌就一直在动。比圆钮高一截（两行字要的高），对话按它让出（`floatingHeader` 的 `height`）。
/// 点它从顶部长出面板（`GrowPanel`，同一块玻璃长大）：名牌原地长成名片（头像放大到页头那一档、名字与此刻排在它下面），下面是 Cue 自己的那几样
/// （`CueNowPanel`：大脑、上下文、记忆、设置），手机上这些只有这一个入口（额度在进展页顶栏的额度环里，在做的会话在进展页的会话段）。
/// 头像只有一个、跟着长大（`PlateLayout`），接力的落点挂在它上面。与 Mac 侧栏的 Cue 名片是同一套件、同一份数据（`CueWatch`）。
/// 点名牌、点面板外、在名牌上往上划都收起；点面板里的一项先收起再去那里。
/// 开面板先收起键盘：面板盖住对话的上半截，键盘弹着时放不下；打开它就是从打字转去看 Cue，草稿留在输入框里，收起面板不再弹回（同推入别的页时交出焦点）。
/// 名牌浮在对话上，展开不改对话的布局，长大的只有这一块；展开与否只在这里（不进 `CueWatch`：侧栏也读它）。
/// 放在 iPad 的系统导航栏里时（`HeaderHost.navigationBar`）名牌不长，面板从它弹出（`GrowPanel`），名片的那一头不出现。
/// 大脑那一行要的（设置与那台 Mac 的 Agent，`observingCueBrain`）随名牌一直订阅着：面板开时才建，长出的第一帧就是真的；其余都是整个窗口已经在订阅的。
struct CueHeader: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.headerHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = DebugHooks.preset.cuePanelOpen
    @State private var brain: AgentModelChoice?

    /// 名牌的高：两行字（名字、此刻）上下各留一截。
    static let height: CGFloat = 56
    /// 名牌的宽：比两侧页边之间窄，名字与此刻居中读。
    static let width: CGFloat = 212

    var body: some View {
        GrowPanel(open: $expanded, radius: Self.height / 2) {
            Button(action: toggle) { CuePlate(card: expanded && host != .navigationBar) }
                .buttonStyle(.plain)
                .simultaneousGesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    if expanded, drag.translation.height < -24 { toggle() }
                })
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint(expanded ? "收起" : "换模型，看上下文、记忆与设置")
        } panel: {
            CueNowPanel(brain: brain, close: toggle)
        }
        .observingCueBrain(into: $brain, fail: workspace.fail)
        .debugExposesCuePanel(toggle)
    }

    private func toggle() {
        if !expanded { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        $expanded.grow(reduceMotion: reduceMotion)
    }
}

/// 名牌本身：收着是定宽定高的两行，`card` 时长成名片（铺满面板的宽、头像放大）。字号两态不变，长大的只有头像。
private struct CuePlate: View {
    let card: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 收着时头像缩到页头那一档的一半：与名字那一行同高。
    private static let small: CGFloat = 0.5

    var body: some View {
        let cue = workspace.cue
        let side = CueAvatar.Size.header.box * (card ? 1 : Self.small)
        PlateLayout(card: card) {
            CueAvatar(mood: cue.mood(composing: !cue.draft.isEmpty(accepting: .images)), presence: cue.presence, size: .header)
                .scaleEffect(card ? 1 : Self.small)
                .frame(width: side, height: side)
                .relaySpot(cue: .header)
            name(cue.name, shown: !card)
            name(cue.name, shown: card)
            CueStatusLine(tally: true, font: .caption).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.top, card ? 18 : 0).padding(.bottom, card ? 2 : 0)
        .frame(width: card ? nil : CueHeader.width, height: card ? nil : CueHeader.height)
        .frame(maxWidth: card ? .infinity : nil)
        // 收着是定高的两行：字号跟着动态字体放大到这一档为止，再大第二行就被裁掉
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .contentShape(.rect)
        .animation(HandOff.quick, value: cue.presence)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: cue.now)
        .accessibilityElement(children: .combine)
    }

    /// 名字两处各一份：头像右边（收着）与头像下面（名片）。两处之间要从长大的头像底下穿过去，所以不挪，原处淡出、新处淡入：
    /// 两份走同一条曲线、同时起，任一帧浓淡相加是一，名字每一帧都读得到（先淡完再淡入的话中间有几帧名字整个没了）。
    private func name(_ name: String, shown: Bool) -> some View {
        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
            // 只有透明度走这条曲线，位置跟着头像同一条弹簧
            .animation(HandOff.quick) { $0.opacity(shown ? 1 : 0) }
            .accessibilityHidden(!shown)
    }
}

/// 名牌里头像、名字、此刻的摆法，两态是同一组视图：头像只有一个，开合时连续地长大挪位；名字两处各一份（头像右边、头像下面，`CuePlate.name`）。
/// 收着时头像接名字一行、此刻一行；名片时头像在上，名字、此刻依次在下。每一行都居中，整组在给的高里竖直居中。
/// 子视图依次是头像、头像右边的名字、头像下面的名字、此刻。
private struct PlateLayout: Layout {
    let card: Bool

    private static let nameGap: CGFloat = 6
    private static let lineGap: CGFloat = 2
    private static let cardGap: CGFloat = 8

    private struct Sizes {
        var avatar: CGSize, rowName: CGSize, cardName: CGSize, line: CGSize
        var row: CGFloat { max(avatar.height, rowName.height) }
    }

    private func sizes(_ width: CGFloat?, _ subviews: Subviews) -> Sizes {
        let avatar = subviews[0].sizeThatFits(.unspecified)
        let wide = ProposedViewSize(width: width, height: nil)
        return Sizes(
            avatar: avatar,
            rowName: subviews[1].sizeThatFits(ProposedViewSize(width: width.map { max($0 - avatar.width - Self.nameGap, 0) }, height: nil)),
            cardName: subviews[2].sizeThatFits(wide),
            line: subviews[3].sizeThatFits(wide))
    }

    private func height(_ s: Sizes) -> CGFloat {
        card ? s.avatar.height + Self.cardGap + s.cardName.height + Self.lineGap + s.line.height : s.row + Self.lineGap + s.line.height
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let s = sizes(proposal.width, subviews)
        let natural = card ? max(s.avatar.width, s.cardName.width, s.line.width) : max(s.avatar.width + Self.nameGap + s.rowName.width, s.line.width)
        return CGSize(width: proposal.width ?? natural, height: height(s))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let s = sizes(bounds.width, subviews)
        let top = bounds.midY - height(s) / 2
        func place(_ index: Int, _ x: CGFloat, _ y: CGFloat, _ anchor: UnitPoint, _ size: CGSize) {
            subviews[index].place(at: CGPoint(x: x, y: y), anchor: anchor, proposal: ProposedViewSize(size))
        }
        if card {
            let below = top + s.avatar.height + Self.cardGap
            place(0, bounds.midX, top, .top, s.avatar)
            place(1, bounds.midX + s.avatar.width / 2 + Self.nameGap, top + s.avatar.height / 2, .leading, s.rowName)
            place(2, bounds.midX, below, .top, s.cardName)
            place(3, bounds.midX, below + s.cardName.height + Self.lineGap, .top, s.line)
        } else {
            let x = bounds.midX - (s.avatar.width + Self.nameGap + s.rowName.width) / 2
            place(0, x, top + s.row / 2, .leading, s.avatar)
            place(1, x + s.avatar.width + Self.nameGap, top + s.row / 2, .leading, s.rowName)
            // 头像下面那份名字贴着小头像的下沿，开合时跟着头像走
            place(2, x + s.avatar.width / 2, top + (s.row + s.avatar.height) / 2, .top, s.cardName)
            place(3, bounds.midX, top + s.row + Self.lineGap, .top, s.line)
        }
    }
}
#endif
