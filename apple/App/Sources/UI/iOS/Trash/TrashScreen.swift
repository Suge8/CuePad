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
                    EmptyState(mascot: .trash, title: "回收站是空的").listRowBackground(Color.clear)
                }
                if !data.projects.isEmpty {
                    Section("项目") {
                        ForEach(data.projects, id: \.project.id) { item in
                            row(title: item.project.name, detail: CountCopy.text((item.cards, "条灵感与任务"))?.visible ?? "", deletedAt: item.project.deletedAt,
                                restore: { try await $0.restoreProject(item.project.id) },
                                purge: { try await $0.purgeProject(item.project.id) })
                        }
                    }
                }
                if !data.cards.isEmpty {
                    Section("灵感与任务") {
                        ForEach(data.cards) { card in
                            let text = CardText(card.body)
                            row(title: text.label, detail: text.preview, deletedAt: card.deletedAt,
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
        let swipes = RowSwipes(
            leading: [RowAction("恢复", symbol: "arrow.uturn.backward", tone: .primary) { workspace.perform(restore) }],
            trailing: [RowAction("永久删除", symbol: "trash", tone: .destructive) { workspace.perform(purge) }])
        // 删除时间单独靠右：摘要再长也不把它挤出去
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(palette.ink).lineLimit(1)
                if !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(palette.ink2).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let deletedAt {
                Text("删于 \(DateLabel.short(deletedAt))").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
            }
        }
        .listRowBackground(palette.paper)
        .listSwipes(swipes)
        .contextMenu { RowActionButtons(actions: swipes.leading + swipes.trailing) }
    }
}

#endif
