import SwiftUI

/// 宽屏主区的第 `index` 个槽（Mac 的 `MainWindow`、iPad 的 `SplitRoot` 各摆 `WideNavigation.maxPanes` 个）：这一排的第几块是什么就画什么。
/// 页那一块（`Workspace.pageHost`）由 `PageLayer` 画，点开盖在它上面的由 `CoverLayer` 画，两样都在别的块上下各一层：页不在这一排时照旧挂在最左的槽里。
/// 块走了以后槽还要滑出去（`WideColumnSlide`），滑完之前照旧画着它。
struct PaneColumn: View {
    let index: Int
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var kept: WideNavigation.Pane?

    var body: some View {
        let column = Workspace.Column(index: index)
        let now = workspace.pane(in: column)
        let hosts = workspace.pageHost == column
        ZStack(alignment: .top) {
            if hosts { PageLayer(column: column) }
            switch now ?? kept {
            case .session(let route)?: SessionLayer(route: route, column: column)
            case .card(let id)?: IdeaPane(cardID: id) { workspace.closeColumn(column) }.id(id)
            case .preview(let owner)?: if let preview = workspace.livePreviews[owner] { LivePreviewPane(preview: preview) }
            case .page?, nil: EmptyView()
            }
            if hosts { CoverLayer() }
        }
        .overlay(alignment: .leading) {
            if index > 0, workspace.liveFill == nil { palette.hair.frame(width: 1).ignoresSafeArea().allowsHitTesting(false) }
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: now) {
            guard now == nil else { return kept = now }
            guard (try? await Task.sleep(for: WideSlide.duration)) != nil else { return }
            kept = nil
        }
    }
}
