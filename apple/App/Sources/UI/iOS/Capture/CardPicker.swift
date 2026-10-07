#if os(iOS)
import CueStore
import SwiftUI

/// 给输入框选一张卡片带上：可搜；当前会话所属项目的卡片在前，其余按最近修改。点一张即选中并收起。
struct CardPicker: View {
    /// 排在前面的项目；nil 不分组。
    let project: UUID?
    let pick: (Card) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var text = ""
    /// 拿去搜的词：输入法组字（拼音还没上屏）时不跟着变，上屏后再搜。
    @State private var settled = ""
    @State private var pages = 1
    @State private var data: Page?

    private nonisolated static let pageSize = 30

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let data {
                        if data.shown == 0, !settled.isEmpty { EmptyState.noMatch(settled) }
                        if !data.pinned.isEmpty {
                            header(workspace.catalog?.project(project)?.name ?? "本项目", project: workspace.catalog?.project(project))
                            rows(data.pinned)
                            if !data.rest.isEmpty { header("其他", project: nil).padding(.top, 8) }
                        }
                        rows(data.rest, showsProject: true)
                        if data.total > data.shown {
                            Button("还有 \(data.total - data.shown) 条") { pages += 1 }.frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(palette.desk)
            .navigationTitle("选一条灵感或任务")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索灵感与任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: text) { if !TextComposition.isComposing { settled = text } }
        .onChange(of: settled) { pages = 1 }
        .observing(services.store, [.cards, .projects], id: Key(text: settled, pages: pages), into: $data, onError: workspace.fail) {
            [project, settled, pages] store in
            try Page.read(text: settled, project: project, limit: Self.pageSize * pages, from: store)
        }
    }

    private func rows(_ entries: [CardEntry], showsProject: Bool = false) -> some View {
        ForEach(entries) { entry in
            CardRow(
                entry: entry, project: showsProject && project == nil ? .some(workspace.catalog?.project(entry.card.projectID)) : nil,
                highlight: settled
            ) { card in
                pick(card)
                dismiss()
            }
        }
    }

    private func header(_ title: String, project: Project?) -> some View {
        HStack(spacing: 6) {
            if let project { ProjectGlyph(project: project, size: 12) }
            SectionHeader(title: title, count: nil).padding(.horizontal, -4)
        }
    }

    private struct Key: Equatable {
        var text: String
        var pages: Int
    }

    /// 一次读到的结果：所属项目的卡片在前（项目只在不分组时为 nil），其余在后；每张卡只出现一次。
    nonisolated struct Page: Sendable {
        var pinned: [CardEntry]
        var rest: [CardEntry]
        var total: Int
        var shown: Int { pinned.count + rest.count }

        static func read(text: String, project: UUID?, limit: Int, from store: isolated CueStore) throws -> Page {
            let all = try store.search(SearchQuery(text: text), limit: limit)
            guard let project else { return Page(pinned: [], rest: all.cards.map(CardEntry.init), total: all.totalCards) }
            let own = try store.search(SearchQuery(text: text, projects: [project]), limit: limit)
            let rest = all.cards.filter { $0.projectID != project }
            return Page(pinned: own.cards.map(CardEntry.init), rest: rest.map(CardEntry.init), total: all.totalCards)
        }
    }
}
#endif
