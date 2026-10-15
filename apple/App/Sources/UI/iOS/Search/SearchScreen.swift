#if os(iOS)
import CueStore
import SwiftUI

/// 搜索页（iPhone 右下的搜索圆钮、iPad 侧栏的"搜索"与 ⌘K，同 Mac 的 ⌘K）：顶上一排是搜索框（iPhone 左边另有设置），
/// 下面两个范围——灵感与任务（`CardSearchResults`，筛选胶囊、按项目分组）、会话（`SessionList`，现在与历史）；一个搜索词两边共用，换范围不清空。
/// 进入、再点搜索圆钮或再按 ⌘K 都聚焦搜索框。
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
    @Environment(\.tabPageReady) private var tabPageReady

    var body: some View {
        Group {
            switch scope {
            case .cards: CardSearchResults(query: $query)
            case .sessions: SessionList(model: sessions, filter: nil)
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                RootBar { SearchCapsule(prompt: "搜索灵感、任务与会话", query: $query.text, focus: $searching) }
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 4)
        }
        .navigationTitle("搜索")
        .toolbarVisibility(navigation.layout == .tabs ? .hidden : .automatic, for: .navigationBar)
        .onChange(of: query.text, initial: true) { sessions.query = query.text }
        .onAppear {
            if query.text.isEmpty { query.text = DebugHooks.preset.searchText }
            tabPageReady?()
        }
        .onChange(of: navigation.searchFocusRequests, initial: true) { focusSearch() }
    }

    /// 聚焦搜索框，不做动画。
    private func focusSearch() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { searching = true }
    }
}
#endif
