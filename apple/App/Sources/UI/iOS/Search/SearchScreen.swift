#if os(iOS)
import SwiftUI

struct SearchScreen: View {
    @State private var query = PaletteQuery()
    @State private var scope = DebugHooks.preset.searchScope
    @State private var sessions = AgentListModel()
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 页宽：导航栏中间那一格不会自己铺满，搜索框按页宽给定宽度（让出左边的返回与两侧页边）。
    @State private var width: CGFloat = 0
    private static let maxField: CGFloat = 560
    static let prompt = String(localized: "搜索灵感、任务与会话")

    var body: some View {
        TurnStack {
            switch scope {
            case .cards: CardSearchResults(query: $query) { scopes }.transition(Motion.turn(from: .leading, reduceMotion: reduceMotion))
            case .sessions:
                SessionList(model: sessions) { ChipRow { scopes }.padding(.horizontal, -Spacing.page) }
                    .transition(Motion.turn(from: .trailing, reduceMotion: reduceMotion))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("搜索", center: {
            SearchCapsule(query: $query.text, focusRequests: workspace.searchFocusRequests).frame(width: fieldWidth)
        }) { EmptyView() }
        .onChange(of: query.text, initial: true) { sessions.query = query.text }
        .debugCyclesTurn { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { scope = scope == .cards ? .sessions : .cards } }
        .onAppear { if query.text.isEmpty { query.text = DebugHooks.preset.searchText } }
    }

    private var fieldWidth: CGFloat {
        let sides = FloatingHeaderLayout.margin * 2 + FloatingHeaderLayout.slot
        return min(Self.maxField, max(0, width - sides))
    }

    private var scopes: some View {
        SearchScopePanes(scope: $scope).frame(height: Self.scopeHeight).turnSteady()
    }

    private static let scopeHeight: CGFloat = 36
}
#endif
