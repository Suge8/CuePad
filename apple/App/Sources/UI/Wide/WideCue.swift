import SwiftUI

/// Mac 只在 Cue 收着时有（窗口右上、压在最右那一块的栏头右端；露着时点 Cue 栏头最右的收起右栏，`CueTitle`，抽屉开着时也不画）；Cue 交活的光点那时落在这里（`relaySpot(cue: .entry)`）。
struct CueButton: View {
    let fits: Bool
    var shown = false
    @Environment(Workspace.self) private var workspace

    #if os(macOS)
    /// 它压在最右那一块的栏头右端，那一块的栏头右边让出：窗边、钮宽、与 × 之间一道缝。
    static let reserve: CGFloat = Spacing.page + ControlMetrics.height + Spacing.item
    #endif

    var body: some View {
        let cue = workspace.cue
        Button {
            if shown { workspace.hideCue(fits: fits) } else { workspace.showCue() }
        } label: {
            avatar
                .overlay(alignment: .topTrailing) { CueDot().offset(x: 2, y: -2) }
                .frame(width: ControlMetrics.height, height: ControlMetrics.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(shown ? "收起 \(cue.name)" : fits ? "放回 \(cue.name)" : "看 \(cue.name)")
        .accessibilityLabel(cue.name)
        .accessibilityValue(shown ? Text("开着") : Text("收着"))
    }

    /// Cue 露着时光点落在它的页头上（`CueSpot.header`），钮不挂入口，不然交活的光飞到钮上去
    @ViewBuilder private var avatar: some View {
        if shown { CueAvatar(workspace.cue.beat, size: .row) } else { CueAvatar(workspace.cue.beat, size: .row).relaySpot(cue: .entry) }
    }
}

extension View {
    func cuePanel(fits: Bool, home: Bool) -> some View { modifier(CuePanel(fits: fits, home: home)) }
}

/// 在右边那一栏时 Cue 住在一块写字玻璃上（同看板列头），浮在主区上、内容往里收一圈：看板放不下的列滑到它下面，不在桌面上切断。
/// 铺满时就是铺满的一页，没有板。玻璃那一层却一直留着，只把它的边推到块外、按块的左右裁掉（`bleed`）：铺满时撤掉玻璃的话，
/// 系统重建块里的图层，让到右边与铺满之间整块先消失再淡入（`WideSlide.Positions` 把它们当新层）；留着，切换就是板的边连续滑出、滑进窗口。
/// 抽屉不是玻璃：它有自己的面（`DrawerSurface`）。玻璃画在块里，收起、放回时随块平移（`WideColumnSlide`）。
/// 板里的对话由调用处按 `corner` 裁：不从板的圆角与上下沿露出去。
struct CuePanel: ViewModifier {
    let fits: Bool
    let home: Bool

    static let float = Spacing.item
    static let radius = Radius.field
    /// 铺满时玻璃的边推到块外这么远：比圆角大，角与边光都落在窗口外或裁掉的那一截里。
    private static let bleed: CGFloat = 48

    static func corner(fits: Bool, home: Bool) -> CGFloat { fits && !home ? radius : 0 }

    func body(content: Content) -> some View {
        let floats = fits && !home, bleeds = fits && home
        content
            .padding(bleeds ? Self.bleed : 0)
            .glass(in: .rect(cornerRadius: Self.radius), ink: .ground(shown: fits))
            .padding(bleeds ? -Self.bleed : floats ? Self.float : 0)
            // 铺满时按块的左右裁（左边是会话条），上下放开：对话照样滚到状态栏与横条后面。浮着时左右也放开：板的影子落在块外。
            // 同一个修饰符只换形状，图层不重建
            .clipShape(Rectangle().scale(x: bleeds ? 1 : 1.5, y: 3))
    }
}

/// 铺满时（`WideMetrics.home`）占会话条之外的整块；让到右边后，放得下时是右边那一栏，放不下时是右缘的抽屉（`Workspace.cueDrawer`），只是同一块的两种摆法，窗口跨过临界宽不拆不建：对话、滚动位置、输入框里的话都在。
/// 摆法只有一个数：露出多宽（`shown`：放得下时是右边那一栏的宽，收起是 0；放不下时抽屉开着是整栏、关着是 0），块的左缘在窗口右缘往里这么远；
/// 露出 0 时排在窗口右缘外，滑出去落定才藏起（看不见、点不到、⌃Tab 跳过），订阅暂停（`pageActive`）。
/// 收起与放回、跨过临界宽、抽屉开合都只是这个数变了，同一段渲染端的平移（`WideColumnSlide`）：主区跟着让出时，块的左缘每一帧贴着主区的右缘。
/// 抽屉的面（`DrawerSurface`）只在放不下时画，画在块里、随块平移；开着时下面先铺一层接点按的透明底（`DrawerCatcher`），盖在主区上，不拿走焦点。
/// 否决过：放得下与放不下各挂一份（右边一份、抽屉在窗口的浮层那一层一份）——跨过临界宽时拆一份建一份，对话回到最新处、读到一半的位置丢了。
struct CueDock<Column: View>: View {
    let sizes: WideMetrics
    let width: CGFloat
    let focus: WideFocus
    /// 块的上沿排在安全区里（iPad 的状态栏底下），抽屉的面往上伸出去这么多，照样铺满整窗高；下沿块自己伸到窗口下缘（`reachesWindowBottom`）。
    var bleed = EdgeInsets()
    @ViewBuilder let column: (_ fits: Bool) -> Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let open = !sizes.cueFits && workspace.cueDrawer
        let shown = sizes.cueFits ? sizes.cue : open ? WideMetrics.cue : 0
        let block = sizes.home ? sizes.cue : WideMetrics.cue
        // 铺满时随窗口变宽不算换形（拖窗口不起滑动）；铺满与让到右边之间、会话条开合才滑
        let shape = sizes.home ? WideMetrics.Shape(rail: sizes.rail, cue: -1) : WideMetrics.Shape(rail: -1, cue: shown)
        ZStack(alignment: .trailing) {
            if open { DrawerCatcher { workspace.hideCue(fits: false) }.transition(.identity) }
            WideColumnHost(slot: .cue, focus: focus, origin: width - shown, width: block, shape: shape, hidden: shown == 0) {
                column(sizes.cueFits)
                    // 铺满时它盖在藏起的会话条上（会话条藏起时照原宽画在下面，`WideRail`）：同主区铺满桌面色，不透出来
                    .background { if sizes.home { palette.desk.ignoresSafeArea() } }
                    .modifier(DrawerSurface(shown: !sizes.cueFits, bleed: bleed))
                    .environment(\.pageActive, shown > 0)
            }
            .frame(width: block)
            .reachesWindowBottom()
            .padding(.trailing, shown - block)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
