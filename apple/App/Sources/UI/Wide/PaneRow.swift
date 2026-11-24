import SwiftUI

/// 宽屏主区的一排（Mac 的 `MainWindow`、iPad 的 `SplitRoot` 共用）。每一块一个托管视图，按它是什么认（`WideMetrics.Piece`），不按排第几：
/// 换了位置、挤宽挤窄都还是那一个视图，位置与宽只是给它的数，页不重摆，焦点、滚动、选区留在原处。
/// 页那一块一直挂着：不在这一排时垫在最左那块底下藏着，回来不用重排。从右头走掉的块滑出去之前照旧画着（`Workspace.leaving`）。
/// 兄弟视图的先后只看块是什么、与位置无关（`Item.id`）：换位时系统不用挪视图。
struct PaneRow: View {
    let sizes: WideMetrics
    let window: CGFloat
    let focus: WideFocus
    /// 第 `index` 块栏头两侧让出多少。
    let inset: (_ index: Int) -> EdgeInsets
    @Environment(Workspace.self) private var workspace

    private struct Item: Identifiable {
        let pane: WideNavigation.Pane?
        /// 在这一排第几块；挂着的页、正滑走的块照它最后会在的那一格算。
        let index: Int
        let placed: Bool
        /// 认这一块的名字，也是兄弟视图的先后（小的在下）：页垫底；活预览在最上，铺满时从会话上面长开、收回时盖着会话滑回去。
        /// 活预览按它是谁的认：换成另一个会话的是另一块，网页不沿用。
        var id: String {
            switch pane {
            case .page?, nil: "0"
            case .session(let route)?: "1\(route.id)"
            case .card(let id)?: "2\(id)"
            case .preview(let owner)?: "3\(owner)"
            }
        }
    }

    private var items: [Item] {
        let panes = workspace.panes
        var items = panes.indices.map { Item(pane: panes[$0], index: $0, placed: true) }
        if !panes.contains(where: { $0.page != nil }) { items.append(Item(pane: nil, index: 0, placed: false)) }
        let placed = Set(items.map(\.id))
        items += workspace.leaving.map { Item(pane: $0, index: panes.count, placed: false) }.filter { !placed.contains($0.id) }
        return items.sorted { $0.id < $1.id }
    }

    var body: some View {
        let before = focus.before(sizes)
        let under = sizes.split ? 0 : sizes.cue
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let leading = item.index == 0
                let origin = item.pane == nil || item.placed ? sizes.origin(item.index, window: window) : window
                let left = item.placed ? nil : item.pane.flatMap { before?.spans[WideMetrics.Piece($0)] }
                let width = left?.width ?? sizes.width(item.index) + (leading ? under : 0)
                let grew = before.map { $0.widths.count < sizes.widths.count } == true && item.index == sizes.widths.count - 1
                WideColumnHost(
                    slot: item.placed ? .pane(Workspace.Column(index: item.index)) : nil, focus: focus, origin: origin, width: width, shape: sizes.shape,
                    hidden: !item.placed || (leading ? sizes.fill : origin >= window), under: leading ? under : 0,
                    arrival: before.map { .init(before: $0.shape, edge: grew ? window : nil) }
                ) {
                    PaneColumn(pane: item.pane, index: item.index, placed: item.placed)
                        .environment(\.headInset, inset(item.index))
                        .environment(\.underCue, leading ? under : 0)
                        #if os(macOS)
                        .environment(\.pageActive, !(leading && sizes.fill))
                        #endif
                }
                .frame(width: width)
                .padding(.leading, origin)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                #if os(iOS)
                .reachesWindowBottom()
                #endif
            }
        }
        // 滑走的块摆在窗口右缘外，这一排算下来比窗口宽：框死成窗口的宽、靠左，不然外面按居中摆，整排跟着左移半个块
        .frame(width: window, alignment: .leading)
    }
}

/// 一块里画什么。点开盖在页上的那一层（`CoverLayer`）跟着页那一块；页不在这一排时盖在最左那块上。
private struct PaneColumn: View {
    let pane: WideNavigation.Pane?
    let index: Int
    let placed: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let column = Workspace.Column(index: index)
        ZStack(alignment: .top) {
            switch pane {
            case .session(let route)?: SessionLayer(route: route, column: column)
            case .card(let id)?: IdeaPane(cardID: id) { workspace.closeColumn(column) }
            case .preview(let owner)?:
                if let preview = workspace.livePreviews[owner] {
                    LivePreviewPane(preview: preview)
                } else {
                    #if os(macOS)
                    LiveAddressEntry(session: owner)
                    #endif
                }
            case .page?, nil: PageLayer(column: workspace.pageHost)
            }
            if placed, column == workspace.pageHost { CoverLayer() }
        }
        .overlay(alignment: .leading) {
            if placed, index > 0, workspace.liveFill == nil { palette.hair.frame(width: 1).ignoresSafeArea().allowsHitTesting(false) }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}
