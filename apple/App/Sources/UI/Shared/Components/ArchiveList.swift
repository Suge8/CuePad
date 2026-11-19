import CueStore
import SwiftUI

struct ArchiveList: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var cards: [Card]?

    var body: some View {
        Group {
            if cards?.isEmpty == true {
                // 空态不放进列表：列表的行内边距会让纸缩进一层，和页面的边线（Mac 的标题、iPhone 的页边距）对不齐
                ScrollView {
                    EmptyState(mascot: .clean, title: "还没有归档的", message: "做完的灵感与任务归档后放在这里")
                        #if os(iOS)
                        .padding(.horizontal, Spacing.block)
                        #endif
                }
            } else {
                #if os(macOS)
                ScrollView {
                    LazyVStack(spacing: 0) { ForEach(cards ?? []) { card in row(card) } }.storedList()
                }
                #else
                List {
                    ForEach(cards ?? []) { card in row(card) }
                }
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .animation(Motion.fade, value: cards?.map(\.id))
        .observing(services.store, into: $cards, onError: workspace.fail) { try $0.archived() }
    }

    private func row(_ card: Card) -> some View {
        let project = workspace.catalog?.project(card.projectID)
        #if os(macOS)
        return Button { open(card) } label: {
            StoredRow(title: card.title, detail: project?.shownName ?? "", stamp: card.archivedAt.map { Text("\(DateLabel.short($0)) 归档") }) {
                mark(card)
            } actions: {
                Button("取回") { workspace.perform { try await $0.unarchive(card.id) } }
            }
        }
        .buttonStyle(CardOpenStyle())
        .contextMenu {
            let swipes = swipes(card)
            RowActionButtons(actions: swipes.leading + swipes.trailing).menuIcons()
        }
        #else
        return Button { open(card) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                mark(card).frame(width: 20)
                MetaLine(spacing: Spacing.item, gap: Spacing.item) {
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        Text(card.title).foregroundStyle(palette.ink).lineLimit(1)
                        Text(project?.shownName ?? "").font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                } meta: {
                    if let archivedAt = card.archivedAt {
                        Text("\(DateLabel.short(archivedAt)) 归档").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .listRowBackground(palette.paper)
        .listSwipes(swipes(card))
        .contextMenu {
            let swipes = swipes(card)
            RowActionButtons(actions: swipes.leading + swipes.trailing).menuIcons()
        }
        #endif
    }

    @ViewBuilder private func mark(_ card: Card) -> some View {
        if card.isTask {
            TaskRingView(status: card.status, done: card.status == .done, size: 17).accessibilityLabel("任务")
        } else {
            Image(.idea).foregroundStyle(palette.ink3).accessibilityLabel("灵感")
        }
    }

    private func swipes(_ card: Card) -> RowSwipes {
        let id = card.id
        return RowSwipes(
            leading: [RowAction("取回", icon: .restore, tone: .primary) { workspace.perform { try await $0.unarchive(id) } }],
            trailing: [CardMenu.Item.trash.rowAction(on: card, in: workspace)].compactMap { $0 })
    }

    private func open(_ card: Card) { workspace.open(card) }
}
