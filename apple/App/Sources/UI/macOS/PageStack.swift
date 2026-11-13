#if os(macOS)
import CueStore
import SwiftUI

/// 读页面的只有这里，主窗口的视图体不读它，切页时不重算整个窗口。会话页不留，只在当前页时挂上。
struct PageStack: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.underCue) private var under

    var body: some View {
        let current = workspace.mainRoute
        let pages = workspace.mountedPages
        let leaving = workspace.pages.leaving
        PageStackLayout(active: current) {
            ForEach(pages, id: \.self) { page in
                let active = page == current
                content(page)
                    .layoutValue(key: PageKey.self, value: page)
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .environment(\.pageActive, active || page == leaving)
                    .environment(\.pagePrefetch, !active && workspace.pages.isPremounted(page))
            }
        }
    }

    @ViewBuilder private func content(_ page: Route) -> some View {
        pageView(page)
            .safeAreaPadding(.top, page.fillsBand ? 0 : Chrome.band)
            .padding(.trailing, page == .progress ? 0 : under)
            .modifier(WindowCardAgents(workspace: workspace))
    }

    @ViewBuilder private func pageView(_ page: Route) -> some View {
        switch page {
        case .shelf: ProjectShelf()
        case .project(let id): ProjectPage(projectID: id)
        case .archive: ArchivePage()
        case .trash: TrashPage()
        case .library: LibraryPage()
        case .cue: CuePage()
        case .progress: TaskBoardPage()
        case .session(let route): if let id = route.sessionID { SessionPage(sessionID: id, column: .main).id(id) }
        default: EmptyView()  // 其余是 iOS 的页
        }
    }
}

private extension Route {
    var fillsBand: Bool {
        switch self {
        case .progress, .session: true
        default: false
        }
    }
}

nonisolated private struct PageKey: LayoutValueKey {
    static let defaultValue: Route? = nil
}

/// 叠放挂着的页：当前页铺满，其余的沿用它们离开时的尺寸（窗口、侧栏怎么变都不再向它们提新尺寸，也就不重排）；
/// 回到前台时按当时的尺寸排一次。不回答对齐查询（默认实现会递归问遍整页子树）。
private struct PageStackLayout: Layout {
    let active: Route

    final class Memo {
        var sizes: [Route: CGSize] = [:]
    }

    func makeCache(subviews: Subviews) -> Memo { Memo() }

    /// 默认的更新会换一份新缓存：窗口每变一次尺寸，挂着的页就忘了自己离开时的尺寸、跟着重排。
    func updateCache(_ cache: inout Memo, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: .zero)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) {
        for subview in subviews {
            guard let page = subview[PageKey.self] else { continue }
            if page == active { cache.sizes[page] = bounds.size }
            subview.place(at: bounds.origin, proposal: ProposedViewSize(cache.sizes[page] ?? bounds.size))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
}
#endif
