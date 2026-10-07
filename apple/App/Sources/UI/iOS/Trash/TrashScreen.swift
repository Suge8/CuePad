#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct TrashData: Sendable {
    var projects: [(project: Project, cards: Int)]
    var cards: [Card]
}

/// 回收站：删除的项目（连同其卡片）与单独删除的卡。左滑永久删除，右滑恢复。
struct TrashScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var data: TrashData?
    @State private var confirmEmpty = false
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            if let data {
                if data.projects.isEmpty && data.cards.isEmpty {
                    ContentUnavailableView("回收站是空的", systemImage: "trash").listRowBackground(Color.clear)
                }
                if !data.projects.isEmpty {
                    Section("项目") {
                        ForEach(data.projects, id: \.project.id) { item in
                            row(title: item.project.name, detail: "\(item.cards) 张卡片", deletedAt: item.project.deletedAt,
                                restore: { try await $0.restoreProject(item.project.id) },
                                purge: { try await $0.purgeProject(item.project.id) })
                        }
                    }
                }
                if !data.cards.isEmpty {
                    Section("卡片") {
                        ForEach(data.cards) { card in
                            let text = CardText(card.body)
                            row(title: text.title.isEmpty ? "空白卡片" : text.title, detail: text.preview, deletedAt: card.deletedAt,
                                restore: { try await $0.restoreCard(card.id) },
                                purge: { try await $0.purgeCard(card.id) })
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .floatingHeader("回收站", detail: data.map { $0.projects.isEmpty && $0.cards.isEmpty ? "空的" : "\($0.projects.count + $0.cards.count) 项" } ?? "") {
            // 圆钮一直在、没东西时置灰：顶栏的控件不随数据出现消失
            Button("清空", systemImage: "trash", role: .destructive) { confirmEmpty = true }
                .disabled(data.map { $0.projects.isEmpty && $0.cards.isEmpty } ?? true)
        }
        .confirmationDialog("永久删除回收站里的全部内容？", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("清空回收站", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        } message: {
            Text("此操作无法撤销。")
        }
        .observing(services.store, [.projects, .cards], into: $data, onError: workspace.fail) { store in
            TrashData(
                projects: try store.trashedProjects().map {
                    ($0, try store.search(SearchQuery(projects: [$0.id], inTrash: true), limit: 0).totalCards)
                },
                cards: try store.trashedCards())
        }
    }

    private func row(
        title: String, detail: String, deletedAt: Date?,
        restore: @escaping @Sendable (CueStore) async throws -> Void, purge: @escaping @Sendable (CueStore) async throws -> Void
    ) -> some View {
        // 删除时间单独靠右：摘要再长也不把它挤出去
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(palette.ink).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(palette.ink2).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let deletedAt {
                Text("\(DateLabel.short(deletedAt)) 删除").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
            }
        }
        .listRowBackground(palette.paper)
        .swipeActions(edge: .leading) {
            Button("恢复", systemImage: "arrow.uturn.backward") { workspace.perform(restore) }.tint(palette.accent)
        }
        .swipeActions(edge: .trailing) {
            Button("永久删除", systemImage: "trash", role: .destructive) { workspace.perform(purge) }
        }
        .contextMenu {
            Button("恢复", systemImage: "arrow.uturn.backward") { workspace.perform(restore) }
            Button("永久删除", systemImage: "trash", role: .destructive) { workspace.perform(purge) }
        }
    }
}

#endif
