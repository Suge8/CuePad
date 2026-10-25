#if os(iOS)
import SwiftUI

/// 搜索页（窄屏项目页顶上的搜索框与进展页的搜索钮、宽屏侧栏顶上的搜索框或 ⌘K，同 Mac 的 ⌘K）：各宽度都推在当前页上，退出就是返回。
/// 搜索框是页顶那一排中间那一块（`floatingHeader`）。两个范围——灵感与任务（`CardSearchResults`）、会话（`SessionList`）——是结果最上面那排胶囊的头两颗，
/// 随结果滚走，不在顶上另占一排；一个搜索词两边共用，换范围不清空。进入、在搜索页上再点搜索框或再按 ⌘K 都聚焦搜索框。
struct SearchScreen: View {
    enum Scope: Hashable, CaseIterable {
        case cards, sessions

        var title: String {
            switch self {
            case .cards: String(localized: "灵感与任务")
            case .sessions: String(localized: "会话")
            }
        }
    }

    @State private var query = PaletteQuery()
    @State private var scope = DebugHooks.preset.searchScope
    @State private var sessions = AgentListModel()
    @Environment(Workspace.self) private var workspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 页宽：导航栏中间那一格不会自己铺满，搜索框按页宽给定宽度（让出左边的返回与两侧页边；宽屏还有侧栏钮与 Cue 面板钮）。
    @State private var width: CGFloat = 0
    private static let maxField: CGFloat = 560
    static let prompt = String(localized: "搜索灵感、任务与会话")

    var body: some View {
        Group {
            switch scope {
            case .cards: CardSearchResults(query: $query) { scopes }
            case .sessions: SessionList(model: sessions, filter: nil) { ChipRow { scopes }.padding(.horizontal, -16) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("搜索", center: {
            SearchCapsule(query: $query.text, focusRequests: workspace.searchFocusRequests).frame(width: fieldWidth)
        }) { EmptyView() }
        .onChange(of: query.text, initial: true) { sessions.query = query.text }
        .onAppear { if query.text.isEmpty { query.text = DebugHooks.preset.searchText } }
    }

    private var fieldWidth: CGFloat {
        let sides = FloatingHeaderLayout.margin * 2 + FloatingHeaderLayout.slot * (sizeClass == .compact ? 1 : 3)
        return min(Self.maxField, max(0, width - sides))
    }

    /// 范围：结果最上面那排胶囊的头两颗。
    @ViewBuilder private var scopes: some View {
        ForEach(Scope.allCases, id: \.self) { item in
            Button { scope = item } label: { FilterChip(on: scope == item) { Text(item.title) } }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(scope == item ? .isSelected : [])
        }
    }
}
#endif
