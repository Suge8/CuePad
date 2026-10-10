#if os(iOS)
import CueStore
import SwiftUI

/// 未分类：还没归进项目的灵感，一条一行，最近的在前。点开看全文；轻扫同所有灵感（`CardMenu.swipes`），移到项目在长按菜单里（归完就离开这里）；
/// 交给过 Agent 的行尾是那个会话的状态点。
struct InboxScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var cards: [Card]?

    var body: some View {
        List {
            if let cards {
                if cards.isEmpty {
                    EmptyIdeas { navigation.startCapture(project: .some(nil)) }
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(cards) { card in row(card) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .animation(Motion.quick, value: cards?.map(\.id))
        .floatingHeader(CaptureCopy.inbox, detail: cards.map { $0.isEmpty ? "空的" : "\($0.count) 条" } ?? "")
        .observing(services.store, into: $cards, onError: workspace.fail) { store in
            try store.cards(in: nil).sorted { $0.modifiedAt > $1.modifiedAt }
        }
    }

    private func row(_ card: Card) -> some View {
        let text = CardText(card.body)
        return Button { navigation.open(card: card.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.label).font(.body.weight(.medium))
                        .foregroundStyle(palette.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    AgentDot(card: card.id).padding(.vertical, -8)
                }
                if !text.preview.isEmpty {
                    Text(text.preview).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                }
                Text(DateLabel.short(card.modifiedAt)).font(.caption).foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
        .listSwipes(.card(card, workspace: workspace))
        .contextMenu { CardActions(card: card) }
    }
}
#endif
