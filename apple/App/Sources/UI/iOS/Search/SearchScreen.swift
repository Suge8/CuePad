#if os(iOS)
import SwiftUI

/// 搜索页（窄屏三页根上的搜索钮、宽屏侧栏顶上的搜索框或 ⌘K，同 Mac 的 ⌘K）：各宽度都推在当前页上，退出就是返回。
/// 宽屏导航栏里还有侧栏钮与 Cue 面板钮，放不下一整条，搜索框在导航栏下面那一排。两个范围——灵感与任务（`CardSearchResults`）、会话（`SessionList`）；
/// 一个搜索词两边共用，换范围不清空。进入、在搜索页上再点搜索框或再按 ⌘K 都聚焦搜索框。
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

    @State private var query = PaletteQuery()
    @State private var scope = DebugHooks.preset.searchScope
    @State private var sessions = AgentListModel()
    @FocusState private var searching: Bool
    @Environment(Workspace.self) private var workspace
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
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                if !compact { field }
                Picker("范围", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 4)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 标题给读屏、返回菜单与系统；窄屏标题那一格是搜索框
        .navigationTitle("搜索")
        .toolbar {
            if compact {
                ToolbarItem(placement: .principal) { field.frame(width: max(0, width - Self.barInset)) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        .onChange(of: query.text, initial: true) { sessions.query = query.text }
        .onAppear { if query.text.isEmpty { query.text = DebugHooks.preset.searchText } }
        .onChange(of: workspace.searchFocusRequests, initial: true) { focusSearch() }
    }

    private var compact: Bool { sizeClass == .compact }

    private var field: some View { SearchCapsule(prompt: "搜索灵感、任务与会话", query: $query.text, focus: $searching) }

    private func focusSearch() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { searching = true }
    }
}

/// 搜索框：玻璃胶囊（搜索页顶上）。在输入或有字时右端一个叉：清空并收起键盘。
struct SearchCapsule: View {
    static let height: CGFloat = ControlMetrics.height
    let prompt: String
    @Binding var query: String
    let focus: FocusState<Bool>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(.search).foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $query, palette: palette).submitLabel(.search).focused(focus).accessibilityLabel("搜索")
            if !query.isEmpty || focus.wrappedValue {
                Button("清除", icon: .clear) {
                    query = ""
                    focus.wrappedValue = false
                }
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .quiet, compact: true))
            }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: Self.height)
        .glass(in: .capsule)
    }
}
#endif
