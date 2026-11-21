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
