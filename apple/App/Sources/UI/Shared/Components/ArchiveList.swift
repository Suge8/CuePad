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
                let runs = (cards ?? []).runs { $0.projectID }
                #if os(macOS)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.part) {
                        ForEach(runs) { run in
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                ProjectRunHeader(project: workspace.catalog?.project(run.id), count: run.items.count)
                                VStack(spacing: 0) { ForEach(run.items) { card in row(card) } }
                            }
                        }
                    }
                    .storedList()
                }
                #else
                List {
                    ForEach(runs) { run in
                        Section {
                            ForEach(run.items) { card in row(card) }
                        } header: {
                            ProjectRunHeader(project: workspace.catalog?.project(run.id), count: run.items.count).textCase(nil)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                #endif
            }
        }
        .animation(Motion.fade, value: cards?.map(\.id))
        .observing(services.store, into: $cards, onError: workspace.fail) { try $0.archived() }
    }

    private func row(_ card: Card) -> some View {
        #if os(macOS)
        return Button { open(card) } label: {
            StoredRow(title: card.title, detail: "", stamp: card.archivedAt) {
                CardKindMark(card: card)
            } actions: {
                Button("取回", icon: .restore) { workspace.perform { try await $0.unarchive(card.id) } }.help("取回")
            }
        }
        .buttonStyle(RowOpenStyle())
        .contextMenu {
            let swipes = swipes(card)
            RowActionButtons(actions: swipes.leading + swipes.trailing).menuIcons()
        }
        #else
        return Button { open(card) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                CardKindMark(card: card).frame(width: CardKindMark.column)
                MetaLine(spacing: Spacing.item, gap: Spacing.item) {
                    Text(card.title).foregroundStyle(palette.ink).lineLimit(1)
                } meta: {
                    if let archivedAt = card.archivedAt {
                        Text(DateLabel.short(archivedAt)).font(Typography.meta).foregroundStyle(palette.ink3)
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

    private func swipes(_ card: Card) -> RowSwipes {
        let id = card.id
        return RowSwipes(
            leading: [RowAction("取回", icon: .restore, tone: .primary) { workspace.perform { try await $0.unarchive(id) } }],
            trailing: [CardMenu.Item.trash.rowAction(on: card, in: workspace)].compactMap { $0 })
    }

    private func open(_ card: Card) { workspace.open(card) }
}

struct CardKindMark: View {
    let card: Card
    @Environment(\.palette) private var palette

    static let column: CGFloat = 20

    var body: some View {
        if card.isTask {
            TaskRingView(status: card.status, done: card.status == .done, size: 17).accessibilityLabel("任务")
        } else {
            Image(.idea).foregroundStyle(palette.ink3).accessibilityLabel("灵感")
        }
    }
}
