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
    func cuePanel(fits: Bool) -> some View { modifier(CuePanel(fits: fits)) }
}

/// 在右栏时 Cue 住在一块玻璃上（同看板列头），浮在主区上、内容往里收一圈：看板放不下的列滑到它下面，不在桌面上切断。
/// 抽屉不是玻璃：它有自己的面（`DrawerSurface`）。玻璃画在块里，收起、放回时随块平移（`WideColumnSlide`）。
/// 板里的对话由调用处按 `corner` 裁：不从板的圆角与上下沿露出去。
struct CuePanel: ViewModifier {
    let fits: Bool

    static let float = Spacing.item
    static let radius = Radius.field

    static func corner(fits: Bool) -> CGFloat { fits ? radius : 0 }

    func body(content: Content) -> some View {
        content
            .glass(in: .rect(cornerRadius: Self.radius), ink: .ground, shown: fits)
            .padding(fits ? Self.float : 0)
    }
}

struct CueDock<Column: View>: View {
    let sizes: WideMetrics
    let width: CGFloat
    let focus: WideFocus
    var bleed = EdgeInsets()
    @ViewBuilder let column: (_ fits: Bool) -> Column
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let open = !sizes.cueFits && workspace.cueDrawer
        let shown = sizes.cueFits ? sizes.cue : open ? WideMetrics.cue : 0
        ZStack(alignment: .trailing) {
            if open { DrawerCatcher { workspace.hideCue(fits: false) }.transition(.identity) }
            WideColumnHost(slot: .cue, focus: focus, origin: width - shown, width: WideMetrics.cue, shape: WideMetrics.Shape(rail: -1, cue: shown), hidden: shown == 0) {
                column(sizes.cueFits)
                    .modifier(DrawerSurface(shown: !sizes.cueFits, bleed: bleed))
                    .environment(\.pageActive, shown > 0)
            }
            .frame(width: WideMetrics.cue)
            .reachesWindowBottom()
            .padding(.trailing, shown - WideMetrics.cue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
