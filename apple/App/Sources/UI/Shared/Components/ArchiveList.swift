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
        Group {
            if cards?.isEmpty == true {
                // 空态不放进列表：列表的行内边距会让纸缩进一层，和页面的边线（Mac 的标题、iPhone 的页边距）对不齐
                ScrollView {
                    EmptyState(mascot: .clean, title: "归档是空的", message: "做完的灵感与任务归档后放在这里")
                        #if os(iOS)
                        .padding(.horizontal, 16)
                        #endif
                }
            } else {
                List {
                    ForEach(cards ?? []) { card in row(card) }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .animation(Motion.quick, value: cards?.map(\.id))
        .observing(services.store, [.cards, .projects], into: $cards, onError: workspace.fail) { try $0.archived() }
    }

    private func row(_ card: Card) -> some View {
        let project = workspace.catalog?.project(card.projectID)
        return Button { open(card) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if card.isTask {
                        TaskRingView(status: card.status, ring: .plain, done: card.status == .done, size: 17)
                    } else {
                        Image(systemName: "lightbulb").foregroundStyle(palette.ink3)
                    }
                }
                .frame(width: 20)
                .accessibilityElement()
                .accessibilityLabel(card.isTask ? "任务" : "灵感")
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).foregroundStyle(palette.ink).lineLimit(1)
                    Text(project?.name ?? CaptureCopy.inbox).font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let archivedAt = card.archivedAt {
                    Text("\(DateLabel.short(archivedAt)) 归档").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
        #if os(iOS)
        .listSwipes(swipes(card))
        #endif
        .contextMenu {
            let swipes = swipes(card)
            RowActionButtons(actions: swipes.leading + swipes.trailing)
        }
    }

    /// 右滑取回，左滑删除（可撤销）；长按菜单是同样两项。
    private func swipes(_ card: Card) -> RowSwipes {
        let id = card.id
        return RowSwipes(
            leading: [RowAction("取回", symbol: "arrow.uturn.backward", tone: .primary) { workspace.perform { try await $0.unarchive(id) } }],
            trailing: [RowAction(CardMenu.Item.trash.title, symbol: CardMenu.Item.trash.symbol, tone: .destructive) {
                workspace.attempt { try await workspace.trash(id) }
            }])
    }

    private func open(_ card: Card) {
        #if os(iOS)
        if card.isTask { navigation.openTask(card.id) } else { navigation.open(card: card.id) }
        #else
        workspace.openCard = card.id
        #endif
    }
}
