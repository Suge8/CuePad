import SwiftUI

struct CueButton: View {
    let fits: Bool
    var shown = false
    @Environment(Workspace.self) private var workspace

    #if os(macOS)
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
    private static let bleed: CGFloat = 48

    static func corner(fits: Bool, home: Bool) -> CGFloat { fits && !home ? radius : 0 }

    func body(content: Content) -> some View {
        let floats = fits && !home, bleeds = fits && home
        content
            .padding(bleeds ? Self.bleed : 0)
            .glass(in: .rect(cornerRadius: Self.radius), ink: .ground, shown: fits)
            .padding(bleeds ? -Self.bleed : floats ? Self.float : 0)
            .clipShape(Rectangle().scale(x: bleeds ? 1 : 1.5, y: 3))
    }
}

struct CueDock<Column: View>: View {
    let sizes: WideMetrics
    let width: CGFloat
    let focus: WideFocus
    var bleed = EdgeInsets()
    @ViewBuilder let column: (_ fits: Bool) -> Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let open = !sizes.cueFits && workspace.cueDrawer
        let shown = sizes.cueFits ? sizes.cue : open ? WideMetrics.cue : 0
        let block = sizes.home ? sizes.cue : WideMetrics.cue
        let shape = sizes.home ? WideMetrics.Shape(rail: sizes.rail, cue: -1) : WideMetrics.Shape(rail: -1, cue: shown)
        ZStack(alignment: .trailing) {
            if open { DrawerCatcher { workspace.hideCue(fits: false) }.transition(.identity) }
            WideColumnHost(slot: .cue, focus: focus, origin: width - shown, width: block, shape: shape, hidden: shown == 0) {
                column(sizes.cueFits)
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
