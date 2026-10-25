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
    /// 页宽：导航栏中间那一格不会自己铺满，搜索框按页宽给定宽度（让出左边的返回与两侧页边；宽屏还有侧栏钮与 Cue 面板钮）。
    @State private var width: CGFloat = 0
    private static let maxField: CGFloat = 560
    static let prompt = "搜索灵感、任务与会话"

    var body: some View {
        Group {
            switch scope {
            case .cards: CardSearchResults(query: $query) { scopes }
            case .sessions: SessionList(model: sessions, filter: nil) { ChipRow { scopes }.padding(.horizontal, -16) }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // 标题给读屏、返回菜单与系统
        .floatingHeader("搜索", center: { field.frame(width: fieldWidth) }) { EmptyView() }
        .onChange(of: query.text, initial: true) { sessions.query = query.text }
        .onAppear { if query.text.isEmpty { query.text = DebugHooks.preset.searchText } }
        .onChange(of: workspace.searchFocusRequests, initial: true) { focusSearch() }
    }

    private var fieldWidth: CGFloat {
        let sides = 32 + FloatingHeaderLayout.slot * (sizeClass == .compact ? 1 : 3)
        return min(Self.maxField, max(0, width - sides))
    }

    private var field: some View { SearchCapsule(prompt: Self.prompt, query: $query.text, focus: $searching) }

    /// 范围：结果最上面那排胶囊的头两颗。
    @ViewBuilder private var scopes: some View {
        ForEach(Scope.allCases, id: \.self) { item in
            Button { scope = item } label: { FilterChip(on: scope == item) { Text(item.title) } }
                .buttonStyle(PressStyle())
                .accessibilityAddTraits(scope == item ? .isSelected : [])
        }
    }

    private func focusSearch() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { searching = true }
    }
}

/// 项目页顶上中间的搜索入口：长相同搜索框（`SearchCapsule`），点了推入搜索页并聚焦搜索框。
struct SearchEntry: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: workspace.openSearch) {
            HStack(spacing: 6) {
                Image(.search).accessibilityHidden(true)
                Text(SearchScreen.prompt).lineLimit(1)
            }
            .foregroundStyle(palette.ink3)
            .padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading)
            .headerPiece()
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("搜索")
    }
}

/// 搜索框：页顶那一排中间的一块写字玻璃（`headerPiece`）。在输入或有字时右端一个叉：清空并收起键盘。
struct SearchCapsule: View {
    static let height: CGFloat = ControlMetrics.height
    let prompt: String
    @Binding var query: String
    let focus: FocusState<Bool>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            // 导航栏里的项会把符号放大一档：定在常规档，与项目页那条搜索入口、进展页搜索钮里的放大镜一样大
            Image(.search).imageScale(.medium).foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $query, palette: palette).submitLabel(.search).focused(focus).accessibilityLabel("搜索")
            if !query.isEmpty || focus.wrappedValue {
                Button("清除", icon: .clear) {
                    query = ""
                    focus.wrappedValue = false
                }
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .quiet, compact: true))
            }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity)
        .headerPiece()
    }
}
#endif
