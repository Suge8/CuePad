import CueStore
import SwiftUI

/// 归档：做完或不再需要的灵感与任务，留着可搜、不占列表；最近归档的在前，一条一行（任务连同它的下级一起归档，只列它自己）。
/// 点一条打开它；"取回"连同下级回到原处，"删除"进回收站。iOS 与 Mac 同一份内容，外框各自。
struct ArchiveList: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif
    @State private var cards: [Card]?

    var body: some View {
        List {
            if let cards {
                if cards.isEmpty {
                    EmptyState(mascot: .clean, title: "归档是空的", message: "做完或不再需要的灵感与任务，归档后在这里，照样搜得到")
                        .listRowBackground(Color.clear)
                }
                ForEach(cards) { card in row(card) }
            }
        }
        .scrollContentBackground(.hidden)
        .animation(Motion.quick, value: cards?.map(\.id))
        .observing(services.store, [.cards, .projects], into: $cards, onError: workspace.fail) { try $0.archived() }
    }

    static func count(_ cards: [Card]?) -> String { cards.map { $0.isEmpty ? "空的" : "\($0.count) 条" } ?? "" }

    private func row(_ card: Card) -> some View {
        let project = workspace.catalog?.project(card.projectID)
        return Button { open(card) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: card.isTask ? TaskGlyph.symbol(card.status) : "lightbulb")
                    .foregroundStyle(palette.ink3).frame(width: 20).accessibilityLabel(card.isTask ? "任务" : "灵感")
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).foregroundStyle(palette.ink).lineLimit(1)
                    Text(project?.name ?? CaptureCopy.inbox).font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let archivedAt = card.archivedAt {
                    Text("\(DateLabel.short(archivedAt)) 归档").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
        #if os(iOS)
        .swipeActions(edge: .leading) { restore(card).tint(palette.signature) }
        .swipeActions(edge: .trailing) { trash(card) }
        #endif
        .contextMenu {
            restore(card)
            trash(card)
        }
    }

    private func restore(_ card: Card) -> some View {
        let id = card.id
        return Button("取回", systemImage: "arrow.uturn.backward") { workspace.perform { try await $0.unarchive(id) } }
    }

    private func trash(_ card: Card) -> some View {
        let id = card.id
        return Button("删除", systemImage: "trash", role: .destructive) { workspace.perform { try await $0.trashCard(id) } }
    }

    private func open(_ card: Card) {
        #if os(iOS)
        if card.isTask { navigation.openTask(card.id) } else { navigation.open(card: card.id) }
        #else
        workspace.openCard = card.id
        #endif
    }
}
