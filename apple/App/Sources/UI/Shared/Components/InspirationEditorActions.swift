import CueStore
import CueText
import SwiftUI

struct InspirationEditorActions: View {
    let card: Card
    let editing: CardEditing
    let sharing: InspirationSharing

    var body: some View {
        Group {
            Menu("分享", icon: .share) {
                Button("排成图片") { share(originals: false) }
                Button("原图") { share(originals: true) }
                Button("文字") {
                    sharing.present(InspirationPayload(files: nil, urls: [], text: CueFormat.plainText(Outgoing.text(body: latestText, values: card.variableValues))))
                }
            }.disabled(editing.text.isEmpty || sharing.isBusy)
            Divider()
            CardActions(card: card, more: true).labelStyle(.titleAndIcon)
        }
    }

    private var latestText: String { editing.handle.text ?? editing.text }

    private func share(originals: Bool) {
        sharing.prepare(source: CueVariables.fill(latestText, values: card.variableValues), originals: originals)
    }
}

extension View {
    /// 一条灵感的编辑：读这张卡、建它唯一的编辑器、离开时落盘；卡没了或被转成任务（变成任务或挂到任务下）就收起（`gone`），转成的任务接着打开。
    func ideaEditing(
        _ cardID: UUID, card: Binding<Card?>, editing: Binding<CardEditing?>, made: @escaping (CardEditing) -> Void = { _ in }, gone: @escaping () -> Void
    ) -> some View {
        modifier(IdeaEditing(cardID: cardID, card: card, editing: editing, made: made, gone: gone))
    }
}

private struct IdeaEditing: ViewModifier {
    let cardID: UUID
    @Binding var card: Card?
    @Binding var editing: CardEditing?
    let made: (CardEditing) -> Void
    let gone: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content
            .observing(services.store, id: cardID, into: $card, onError: { [workspace, gone] error in
                if case CueStoreError.notFound = error { return gone() }
                workspace.fail(error)
            }) { [cardID] store in
                guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
                return card
            }
            .onChange(of: card?.id, initial: true) {
                guard editing == nil, let card else { return }
                let made = CardEditing(card, workspace: workspace)
                editing = made
                self.made(made)
            }
            .onChange(of: card?.deletedAt != nil) { _, deleted in if deleted { gone() } }
            .onChange(of: card.map { $0.isTask || $0.parentID != nil }) { _, moved in
                guard moved == true, let card else { return }
                gone()
                workspace.open(card)
            }
            .onDisappear { editing?.leave() }
    }
}

struct InspirationShareRequest: Identifiable {
    let id = UUID()
    let source: String
    let originals: Bool
}

struct InspirationSharePresentation: ViewModifier {
    let sharing: InspirationSharing
    let editing: CardEditing?

    func body(content: Content) -> some View {
        content
            .background {
                if let session = sharing.session {
                    InspirationSystemShare(session: session).id(session.id)
                }
            }
            .panel(item: Binding(get: { sharing.request }, set: { if $0 == nil { sharing.cancelPreparation() } }), style: .bubble(.unanchored)) { snapshot in
                InspirationExport(source: snapshot.source, originals: snapshot.originals, close: sharing.cancelPreparation, recover: recover) { result in
                    sharing.prepared(result, for: snapshot)
                }
            }
            .onChange(of: editing?.cardID) { sharing.leave() }
            .onDisappear { sharing.leave() }
    }

    private func recover(_ action: InspirationShare.Recovery) {
        sharing.cancelPreparation()
        if action == .edit { editing?.handle.focus() }
    }
}
