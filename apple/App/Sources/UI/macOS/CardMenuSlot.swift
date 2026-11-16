#if os(macOS)
import CueStore
import SwiftUI

/// 编辑浮层开着时栏头右端的置顶、删除与"⋯"：那张卡的操作（iPad 的编辑页自己那一排有，`HeaderHost.panel`）。卡还没读到时钮在、置灰。
struct CardMenuSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    /// 外层 nil 是还没读到。
    @State private var opened: Card??
    @State private var inspirationSharing = InspirationSharing()

    var body: some View {
        let card = (opened ?? nil).flatMap { $0.id == workspace.openCard ? $0 : nil }
        // 三颗在同一块玻璃里：各一颗玻璃圆钮排开，像三件不相干的事
        HStack(spacing: 0) {
            if let card { CardQuickButtons(card: card).labelStyle(.iconOnly) }
            Menu { if let card { items(card).labelStyle(.titleAndIcon) } } label: { Image(.more) }
                .menuStyle(.button).menuIndicator(.hidden)
                .disabled(card == nil)
                .help("分享、移到项目、复制、归档")
                .accessibilityLabel("更多")
        }
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .padding(.horizontal, Spacing.tight)
            .frame(height: ControlMetrics.height)
            .glass(in: .capsule)
            .fixedSize()
            .padding(.leading, Spacing.item)
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
