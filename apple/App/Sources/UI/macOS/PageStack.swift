#if os(macOS)
import CueStore
import SwiftUI

/// 内容区：当前页与最近去过的几页都挂着（`Workspace.mountedPages`），切页只是换哪一页看得见，回访不重建、不重排、滚动位置还在。
/// 不在前台的页：不可见、点不到、屏读跳过，暂停订阅与实时状态（`pageActive`），尺寸停在离开时的值（`PageStackLayout`）。
/// 读页面的只有这里，主窗口的视图体不读它，切页时不重建整条工具栏。会话页不留，只在当前页时挂上。
struct PageStack: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.root
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
        pageView(page).modifier(WindowCardAgents(workspace: workspace))
    }

    @ViewBuilder private func pageView(_ page: Route) -> some View {
        switch page {
        case .project(let id): ProjectPage(projectID: id)
        case .archive: ArchivePage()
        case .trash: TrashPage()
        case .cue: CuePage()
        case .progress: ProgressPage()
        case .session(let route): if let id = route.sessionID { SessionPage(sessionID: id).id(id) }
        default: EmptyView()  // 其余是 iOS 的页
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
