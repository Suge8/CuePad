#if os(iOS)
import CueStore
import SwiftUI
import UIKit

nonisolated private struct SearchData: Sendable, Equatable {
    var groups: [Group]
    var total: Int
    var shown: Int
    /// iOS 上可选的发送目标：只有本机能产生的（复制到剪贴板）。Pi 与应用投送是 Mac 专有。
    var targets: [SendTarget]

    /// 结果按项目分组，组按首次出现的顺序（即最相关的在前）。
    struct Group: Identifiable, Sendable, Equatable {
        var id: UUID
        var project: Project?
        var cards: [CardEntry]
    }

    static func grouped(_ cards: [Card], projects: [Project]) -> [Group] {
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var order: [UUID] = []
        var buckets: [UUID: [CardEntry]] = [:]
        for card in cards {
            if buckets[card.projectID] == nil { order.append(card.projectID) }
            buckets[card.projectID, default: []].append(CardEntry(card))
        }
        return order.map { Group(id: $0, project: byID[$0], cards: buckets[$0] ?? []) }
    }
}

/// 卡片搜索的结果（搜索页"灵感与任务"一栏）：筛选胶囊（右边写命中"N 条"）+ 按项目分组的卡片（多个词都要命中，最近修改在前）。
struct CardSearchResults: View {
    @Binding var query: PaletteQuery
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    FilterChips(query: $query, projects: workspace.catalog?.projects ?? [], targets: data?.targets ?? [])
                    if let data, !shown.text.isEmpty || shown.isFiltered {
                        Text(CountCopy.hits(data.total)).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                            .contentTransition(.numericText()).animation(Motion.quick, value: data.total)
                            .fixedSize().padding(.trailing, 16)
                    }
                }
                .padding(.horizontal, -16)
                if let data {
                    if data.total == 0, !shown.text.isEmpty || shown.isFiltered {
                        EmptyState.noMatch(shown.text).padding(.top, 24)
                    }
                    ForEach(data.groups) { group in
                        HStack(spacing: 6) {
                            ProjectGlyph(project: group.project, size: 12)
                            SectionHeader(title: group.project?.name ?? "", count: nil).padding(.horizontal, -4)
                        }
                        .padding(.top, 8)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.cards) { CardRow(entry: $0, highlight: shown.text) }
                        }
                    }
                    if data.total > data.shown {
                        Button("还有 \(data.total - data.shown) 条") { query.pages += 1 }
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
        .observing(services.store, id: shown, into: $data, onError: workspace.fail) { [shown] store in
            let found = try store.search(shown.store(), limit: PaletteQuery.pageSize * shown.pages)
            return SearchData(
                groups: SearchData.grouped(found.cards, projects: try store.projects()), total: found.totalCards, shown: found.cards.count,
                targets: try store.sendTargets())
        }
    }
}

/// 当前输入框是否在输入法组字中（有未上屏的拼音等）。SwiftUI 的搜索框不报告这一点，问第一响应者。
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

/// 筛选胶囊：项目、含图片、发送、时间；生效的填成实心。
private struct FilterChips: View {
    @Binding var query: PaletteQuery
    let projects: [Project]
    let targets: [SendTarget]

    var body: some View {
        ChipRow {
            Menu {
                Button("全部") { query.project = nil }
                Divider()
                ForEach(projects) { project in Button(project.name) { query.project = project.id } }
            } label: { Chip(name: "项目", value: projectLabel, on: query.project != nil) }
            Button { query.withImages.toggle() } label: { Chip(name: "含图片", value: nil, on: query.withImages) }
                .accessibilityAddTraits(query.withImages ? .isSelected : [])
            Menu {
                Button("任意") { query.sent = .any }
                Button("没交给过 Agent") { query.sent = .never }
                Button("交给过 Agent") { query.sent = .sent() }
                if !targets.isEmpty {
                    Divider()
                    ForEach(targets, id: \.filterID) { target in
                        Button(target.name) { query.sent = .sent(kind: target.kind, name: target.name) }
                    }
                }
            } label: { Chip(name: "Agent", value: sentLabel, on: query.sent != .any) }
            Menu {
                ForEach(PaletteQuery.Period.allCases, id: \.self) { period in Button(period.label) { query.period = period } }
            } label: { Chip(name: "时间", value: query.period.label, on: query.period != .any) }
        }
    }

    private var projectLabel: String {
        query.project.flatMap { id in projects.first { $0.id == id }?.name } ?? "全部"
    }

    private var sentLabel: String {
        switch query.sent {
        case .any: "任意"
        case .never: "没交过"
        case .sent(_, .some(let name)): name
        case .sent: "交过"
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
                    Image(.expand).font(.caption2.weight(.bold)).opacity(0.5).accessibilityHidden(true)
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

/// 一颗筛选胶囊（搜索的筛选、会话页的项目）：生效的是选中底（`selection`）与靛青字（选中一律用签名色），其余是纸底细边、墨色字。
struct FilterChip<Label: View>: View {
    let on: Bool
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        label
            .font(.subheadline)
            .fontWeight(on ? .semibold : nil)
            .foregroundStyle(on ? palette.signature : palette.ink)
            .padding(.horizontal, 12).frame(minHeight: 36)
            .background(on ? palette.selection : palette.paper, in: .capsule)
            .overlay { if !on { Capsule().strokeBorder(palette.hair) } }
            .padding(.vertical, 4)
            .contentShape(.rect)
            .animation(Motion.quick, value: on)
    }
}
#endif
