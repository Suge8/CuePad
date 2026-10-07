#if os(iOS)
import CueStore
import SwiftUI
import UIKit

/// 搜索的范围：全部卡片（书架、iPad 搜索页），或一个项目里的卡片（项目页，nil 是未归档）。
enum CardSearchScope: Equatable {
    case all
    case project(UUID?)
}

nonisolated private struct SearchData: Sendable {
    var groups: [Group]
    var total: Int
    var shown: Int
    /// iOS 上可选的发送目标：只有本机能产生的（复制到剪贴板）。Pi 与应用投送是 Mac 专有。
    var targets: [SendTarget]

    /// 结果按项目分组，组按首次出现的顺序（即最相关的在前）。
    struct Group: Identifiable, Sendable {
        var project: Project?
        var cards: [CardEntry]
        var id: UUID? { project?.id }
    }

    static func grouped(_ cards: [Card], projects: [Project]) -> [Group] {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var order: [UUID?] = []
        var buckets: [UUID?: [CardEntry]] = [:]
        for card in cards {
            if buckets[card.projectID] == nil { order.append(card.projectID) }
            buckets[card.projectID, default: []].append(CardEntry(card))
        }
        return order.map { Group(project: $0.flatMap { byID[$0] }, cards: buckets[$0] ?? []) }
    }
}

/// 卡片搜索的结果：筛选胶囊 + 按项目分组的卡片（多个词都要命中，最近修改在前）。书架、项目页与 iPad 搜索页共用；
/// 项目范围内不分组、不出现项目筛选。
struct CardSearchResults: View {
    @Binding var query: PaletteQuery
    let scope: CardSearchScope
    /// 命中总数，给需要在标题上显示的页面（iPad 搜索页）。
    var total: Binding<Int?> = .constant(nil)
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var data: SearchData?
    /// 拿去搜的条件：输入法组字（拼音还没上屏）时不跟着变，上屏后再搜，结果不随每个字母闪"未找到"。
    @State private var settled: PaletteQuery?

    /// 宽屏上结果按可用宽度排成多列。
    private var columns: [GridItem] {
        sizeClass == .regular ? [GridItem(.adaptive(minimum: 320), spacing: 12, alignment: .top)] : [GridItem(.flexible())]
    }

    private var shown: PaletteQuery { settled ?? query }

    private var effective: PaletteQuery {
        var effective = shown
        if case .project(let id) = scope { effective.project = .some(id) }
        return effective
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                FilterChips(query: $query, projects: scope == .all ? workspace.catalog?.projects ?? [] : nil, targets: data?.targets ?? [])
                    .padding(.horizontal, -16)
                if let data {
                    if data.total == 0, !shown.text.isEmpty || shown.isFiltered {
                        ContentUnavailableView.search(text: shown.text)
                    }
                    ForEach(data.groups) { group in
                        if scope == .all {
                            HStack(spacing: 6) {
                                ProjectGlyph(project: group.project, size: 12)
                                SectionHeader(title: group.project?.name ?? "未归档", count: nil).padding(.horizontal, -4)
                            }
                            .padding(.top, 8)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.cards) { CardRow(entry: $0, highlight: shown.text) }
                        }
                    }
                    if data.total > data.shown {
                        Button("还有 \(data.total - data.shown) 张") { query.pages += 1 }
                            .frame(maxWidth: .infinity).padding()
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: query.text) { query.pages = 1 }
        .onAppear { settled = query }
        .onChange(of: query) { if !TextComposition.isComposing { settled = query } }
        .onChange(of: data?.total) { total.wrappedValue = data?.total }
        .observing(services.store, [.cards, .projects, .sendRecords], id: effective, into: $data, onError: workspace.fail) { [effective] store in
            let found = try store.search(effective.store(), limit: PaletteQuery.pageSize * effective.pages)
            return SearchData(
                groups: SearchData.grouped(found.cards, projects: try store.projects()), total: found.totalCards, shown: found.cards.count,
                targets: try store.sendTargets().filter { $0.kind == .known(.clipboard) })
        }
    }
}

extension View {
    /// iPhone 书架与项目页的下拉搜索（系统搜索框在导航栏下，页面在顶上时露出，下滑收起）：搜索时页面换成同一套搜索结果，
    /// 取消搜索回到原页面。iPad 用侧栏与 ⌘K 的搜索页，这里不挂。
    /// `available`：这一页有可搜的卡片（按同步可得的项目目录判断）；`ready`：页面内容已读到、可以挂搜索框。
    func cardSearch(_ scope: CardSearchScope, available: Bool, ready: Bool) -> some View {
        modifier(CardSearch(scope: scope, available: available, ready: ready))
    }
}

private struct CardSearch: ViewModifier {
    let scope: CardSearchScope
    let available: Bool
    let ready: Bool
    @Environment(Navigation.self) private var navigation
    @State private var query = PaletteQuery()
    @FocusState private var focused: Bool

    /// 这一页在导航里的位置：⌘K 指名要聚焦的是不是这一页。
    private var route: Navigation.Route {
        switch scope {
        case .all: .shelf
        case .project(let id): id.map(Navigation.Route.project) ?? .inbox
        }
    }

    private func focusIfRequested() {
        guard navigation.pendingPageSearch == route else { return }
        navigation.pendingPageSearch = nil
        focused = true
    }

    func body(content: Content) -> some View {
        Group {
            if available && ready {
                SearchSwap(query: $query, scope: scope) { content }
                    .searchable(text: $query.text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
                    .searchFocused($focused)
                    .onAppear(perform: focusIfRequested)
                    .onChange(of: navigation.pendingPageSearch) { focusIfRequested() }
                    #if DEBUG
                    .onAppear {
                        guard DebugScene.activatesSearch(scope) else { return }
                        query.text = DebugScene.searchText
                        focused = true
                    }
                    #endif
            } else {
                content
            }
        }
    }

    private var prompt: String { scope == .all ? "搜索全部卡片" : "搜索本项目" }
}

/// 搜索框激活时换成结果；`isSearching` 只在 `.searchable` 之内可读，所以单独成一个视图。
private struct SearchSwap<Content: View>: View {
    @Binding var query: PaletteQuery
    let scope: CardSearchScope
    @ViewBuilder let content: Content
    @Environment(\.isSearching) private var isSearching

    var body: some View {
        if isSearching { CardSearchResults(query: $query, scope: scope) } else { content }
    }
}

/// 当前输入框是否在输入法组字中（有未上屏的拼音等）。SwiftUI 的搜索框不报告这一点，问第一响应者。
@MainActor
enum TextComposition {
    static var isComposing: Bool {
        let probe = FirstResponderProbe()
        UIApplication.shared.sendAction(#selector(UIResponder.cuepadReportFirstResponder(_:)), to: nil, from: probe, for: nil)
        return (probe.responder as? UITextInput)?.markedTextRange != nil
    }
}

private final class FirstResponderProbe: NSObject {
    weak var responder: UIResponder?
}

extension UIResponder {
    /// 发给 nil 目标的动作落在第一响应者上：借此拿到它。
    @objc fileprivate func cuepadReportFirstResponder(_ sender: Any) {
        (sender as? FirstResponderProbe)?.responder = self
    }
}

/// 筛选胶囊：项目（只在全部范围里有）、含图片、发送、时间；生效的填成实心。
private struct FilterChips: View {
    @Binding var query: PaletteQuery
    /// nil：已限定在一个项目里，不出现项目筛选。
    let projects: [Project]?
    let targets: [SendTarget]

    var body: some View {
        ChipRow {
            if let projects {
                Menu {
                    Button("全部") { query.project = nil }
                    Button("未归档") { query.project = .some(nil) }
                    Divider()
                    ForEach(projects) { project in Button(project.name) { query.project = project.id } }
                } label: { Chip(name: "项目", value: projectLabel, on: query.project != nil) }
            }
            Button { query.withImages.toggle() } label: { Chip(name: "含图片", value: nil, on: query.withImages) }
                .accessibilityAddTraits(query.withImages ? .isSelected : [])
            Menu {
                Button("任意") { query.sent = .any }
                Button("从未发送") { query.sent = .never }
                Button("发送或复制过") { query.sent = .sent() }
                if !targets.isEmpty {
                    Divider()
                    ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                        Button(target.name) { query.sent = .sent(kind: target.kind, name: target.name) }
                    }
                }
            } label: { Chip(name: "发送", value: sentLabel, on: query.sent != .any) }
            Menu {
                ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
            } label: { Chip(name: "时间", value: query.period.label, on: query.period != .any) }
        }
    }

    private var projectLabel: String {
        switch query.project {
        case .none: "全部"
        case .some(.none): "未归档"
        case .some(.some(let id)): projects?.first { $0.id == id }?.name ?? "全部"
        }
    }

    private var sentLabel: String {
        switch query.sent {
        case .any: "任意"
        case .never: "从未发送"
        case .sent(_, .some(let name)): name
        case .sent(.known(.clipboard), nil): "剪贴板"
        case .sent: "发送过"
        }
    }
}

/// 搜索的筛选胶囊：名称，生效时加上取值；有菜单的带下拉箭头。
private struct Chip: View {
    let name: String
    let value: String?
    let on: Bool

    var body: some View {
        FilterChip(on: on) {
            HStack(spacing: 4) {
                Text(name).opacity(on ? 0.7 : 1)
                if let value, on {
                    Text(value).fontWeight(.medium)
                }
                if value != nil {
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold)).opacity(0.5).accessibilityHidden(true)
                }
            }
        }
    }
}

/// 一排横向滑动的筛选胶囊。调用方给它让出页边距（`.padding(.horizontal, -16)`），它延伸到边缘、右侧 24pt 渐隐：
/// 看得出还能横着滑，而不是被页边距切断。
struct ChipRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }.padding(.horizontal, 16)
        }
        .mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 24)
            }
        }
    }
}

/// 一颗筛选胶囊（搜索的筛选、Agent 页的项目）：生效的是墨色实心，其余是纸底细边。
struct FilterChip<Label: View>: View {
    let on: Bool
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        label
            .font(.subheadline)
            .foregroundStyle(on ? palette.onAccent : palette.ink)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(on ? palette.accent : palette.paper, in: .capsule)
            .overlay { if !on { Capsule().strokeBorder(palette.hair) } }
            .padding(.vertical, 4)
            .contentShape(.rect)
            .animation(Motion.quick, value: on)
    }
}
#endif
