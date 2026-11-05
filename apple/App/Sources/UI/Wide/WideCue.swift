import SwiftUI

/// Cue 钮（宽屏）：一颗头像钮，有等你或新消息时角上带点（`CueDot`）。Cue 露着时它收起 Cue（`shown`，`Workspace.hideCue`），
/// 收着时放回（`showCue`）：放得下回到右边，放不下从窗口右缘拉出抽屉（`Workspace.cueDrawer`）。
/// Mac 只在 Cue 收着时有（窗口右上、压在最右那一块的栏头右端；露着时点 Cue 栏头最右的收起右栏，`CueTitle`，抽屉开着时也不画）；Cue 交活的光点那时落在这里（`relaySpot(cue: .entry)`）。
/// iPad 一直在会话条顶上那一排：Cue 页的名牌点了是名片面板，收起只有这一处。
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

/// 宽屏右边的 Cue（Mac 的 `MainWindow`、iPad 的 `SplitRoot` 同一份）：一个窗口任何时刻只挂这一块，放得下时是右边那一栏，放不下时是右缘的抽屉（`Workspace.cueDrawer`），
/// 只是同一块的两种摆法，窗口跨过临界宽不拆不建：对话、滚动位置、输入框里的话都在。
/// 摆法只有一个数：露出多宽（`shown`：放得下时是右边那一栏的宽，收起是 0；放不下时抽屉开着是整栏、关着是 0），块的左缘在窗口右缘往里这么远；
/// 露出 0 时排在窗口右缘外，滑出去落定才藏起（看不见、点不到、⌃Tab 跳过），订阅暂停（`pageActive`）。
/// 收起与放回、跨过临界宽、抽屉开合都只是这个数变了，同一段渲染端的平移（`WideColumnSlide`）：主区跟着让出时，块的左缘每一帧贴着主区的右缘。
/// 抽屉的面（`DrawerSurface`）只在放不下时画，画在块里、随块平移；开着时下面先铺一层接点按的透明底（`DrawerCatcher`），盖在主区上，不拿走焦点。
/// 否决过：放得下与放不下各挂一份（右边一份、抽屉在窗口的浮层那一层一份）——跨过临界宽时拆一份建一份，对话回到最新处、读到一半的位置丢了。
struct CueDock<Column: View>: View {
    let sizes: WideMetrics
    /// 窗口宽。
    let width: CGFloat
    let focus: WideFocus
    /// 块只排在安全区里时（iPad），抽屉的面伸出去这么多，照样铺满整窗高。
    var bleed = EdgeInsets()
    /// 这一栏：参数是放不放得下（放不下时它在抽屉里）。
    @ViewBuilder let column: (_ fits: Bool) -> Column
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let open = !sizes.cueFits && workspace.cueDrawer
        let shown = sizes.cueFits ? sizes.cue : open ? WideMetrics.cue : 0
        ZStack(alignment: .trailing) {
            if open { DrawerCatcher { workspace.hideCue(fits: false) }.transition(.identity) }
            WideColumnHost(slot: .cue, focus: focus, origin: width - shown, width: WideMetrics.cue, shape: WideMetrics.Shape(rail: 0, cue: shown), hidden: shown == 0) {
                column(sizes.cueFits)
                    .modifier(DrawerSurface(shown: !sizes.cueFits, bleed: bleed))
                    .environment(\.pageActive, shown > 0)
            }
            .frame(width: WideMetrics.cue)
            .padding(.trailing, shown - WideMetrics.cue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}
