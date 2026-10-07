#if os(iOS)
import CueStore
import SwiftUI

/// iPad 的搜索页（侧栏"搜索"与 ⌘K）：搜索框常驻，进入或再按 ⌘K 都聚焦并全选已有文字。结果是共用的 `CardSearchResults`。
struct SearchScreen: View {
    @Environment(Navigation.self) private var navigation
    @State private var query = PaletteQuery()
    @FocusState private var searching: Bool
    @State private var selection: TextSelection?
    @State private var total: Int?

    var body: some View {
        CardSearchResults(query: $query, scope: .all, total: $total)
            .floatingHeader("搜索", detail: total.map { !query.text.isEmpty || query.isFiltered ? "\($0) 条" : "" } ?? "")
            .searchable(text: $query.text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索灵感与任务")
            .searchFocused($searching)
            .searchSelection($selection)
            .onAppear {
                #if DEBUG
                if query.text.isEmpty { query.text = DebugScene.searchText }
                #endif
                focusSearch()
            }
            .onChange(of: navigation.searchFocusRequests) { focusSearch() }
    }

    /// 聚焦搜索框并全选已有文字（接着打字即替换），不做动画。
    private func focusSearch() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { searching = true }
        // 搜索框成为焦点之后再选中：同一刻设置的选区会被获得焦点时放在末尾的光标覆盖
        Task { @MainActor in selection = TextSelection(range: query.text.startIndex..<query.text.endIndex) }
    }
}
#endif
