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

    var body: some View {
        List {
            if let data {
                if data.projects.isEmpty && data.cards.isEmpty {
                    ContentUnavailableView("回收站是空的", systemImage: "trash")
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
        .deskBackground()
        .navigationTitle("回收站")
        .toolbar {
            if let data, !(data.projects.isEmpty && data.cards.isEmpty) {
                Button("清空", role: .destructive) { confirmEmpty = true }
            }
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
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1)
            Text([detail, deletedAt.map { "\(DateLabel.short($0)) 删除" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .swipeActions(edge: .leading) {
            Button("恢复", systemImage: "arrow.uturn.backward") { workspace.perform(restore) }.tint(.blue)
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
