#if os(macOS)
import CueStore
import SwiftUI

/// 编辑浮层开着时栏头右端的"⋯"：那张卡的操作（iPad 的编辑页自己那一排有，`HeaderHost.panel`）。卡还没读到时钮在、置灰。
struct CardMenuSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    /// 外层 nil 是还没读到。
    @State private var opened: Card??
    @State private var inspirationSharing = InspirationSharing()

    var body: some View {
        let card = (opened ?? nil).flatMap { $0.id == workspace.openCard ? $0 : nil }
        Menu { if let card { items(card).labelStyle(.titleAndIcon) } } label: { Image(.more) }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .fixedSize()
            .padding(.leading, Spacing.item)
            .disabled(card == nil)
            .help("置顶、移到项目、复制、归档、删除")
            .accessibilityLabel("更多")
            .observing(services.store, id: workspace.openCard, into: $opened, onError: workspace.fail) { [id = workspace.openCard] store in
                try id.flatMap { try store.card($0) }
            }
            .modifier(InspirationSharePresentation(sharing: inspirationSharing, editing: workspace.openCardEditing))
    }

    @ViewBuilder private func items(_ card: Card) -> some View {
        if let editing = workspace.openCardEditing, editing.cardID == card.id {
            InspirationEditorActions(card: card, editing: editing, sharing: inspirationSharing)
        } else { CardActions(card: card, more: true) }
    }
}
#endif
