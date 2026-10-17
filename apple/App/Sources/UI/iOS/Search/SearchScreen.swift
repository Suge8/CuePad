#if os(iOS)
import CueStore
import SwiftUI

/// 搜索页（点侧栏列表顶上的搜索框或按 ⌘K 进来，同 Mac 的 ⌘K）：顶上是搜索框（iPhone 在导航栏中间，左边是系统的返回；iPad 是 `RootBar` 那一排），
/// 下面两个范围——灵感与任务（`CardSearchResults`，筛选胶囊、按项目分组）、会话（`SessionList`，现在与历史）；一个搜索词两边共用，换范围不清空。
/// 进入、再点列表的搜索框或再按 ⌘K 都聚焦搜索框。
struct SearchScreen: View {
    enum Scope: Hashable, CaseIterable {
        case cards, sessions

        var title: String {
            switch self {
            case .cards: "灵感与任务"
            case .sessions: "会话"
            }
        }
    }

    @Environment(Navigation.self) private var navigation
    @State private var query = PaletteQuery()
    @State private var scope = DebugHooks.preset.searchScope
    @State private var sessions = AgentListModel()
    @FocusState private var searching: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 页宽：导航栏中间那一格不会自己铺满，搜索框按页宽给定宽度（让出左边的返回与两侧页边）。
    @State private var width: CGFloat = 0
    private static let barInset: CGFloat = 16 + ControlMetrics.height + 8 + 16

    var body: some View {
        Group {
            switch scope {
            case .cards: CardSearchResults(query: $query)
            case .sessions: SessionList(model: sessions, filter: nil)
            }
        }
        .fadesUnderBars(throughTopRow: compact)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if !compact { RootBar { field } }
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }
            .padding(.top, compact ? 4 : 0)
            .padding(.bottom, 4)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("搜索")
        // 标题只给读屏与系统；iPhone 上标题那一格是搜索框
        .toolbar(removing: compact ? nil : .title)
        .toolbar {
            // iPhone：搜索框在导航栏中间那一格，左边是系统的返回（左缘右滑回到列表要导航栏在）
            if compact {
                ToolbarItem(placement: .principal) { field.frame(width: max(0, width - Self.barInset)) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        .onChange(of: query.text, initial: true) { sessions.query = query.text }
        .onAppear { if query.text.isEmpty { query.text = DebugHooks.preset.searchText } }
        .onChange(of: navigation.searchFocusRequests, initial: true) { focusSearch() }
    }

    private var compact: Bool { sizeClass == .compact }

    private var field: some View { SearchCapsule(prompt: "搜索灵感、任务与会话", query: $query.text, focus: $searching) }

    /// 聚焦搜索框，不做动画。
    private func focusSearch() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { searching = true }
    }
}
#endif
