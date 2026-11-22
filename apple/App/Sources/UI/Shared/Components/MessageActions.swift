import CueStore
import CueText
import SwiftUI

struct MessageActions: View {
    let text: String
    let kind: MessageMenu.Kind
    var session: SessionState?
    var selectText: (() -> Void)?
    var annotate: (() -> Void)?
    var resend: (() -> Void)?
    var remove: (() -> Void)?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let sections = MessageMenu.sections(for: kind)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self, content: item)
        }
        .menuIcons()
    }

    @ViewBuilder private func item(_ item: MessageMenu.Item) -> some View {
        switch item {
        case .copy: Button(item.title, icon: item.icon) { workspace.copy(text) }
        case .selectText: if let selectText { Button(item.title, icon: item.icon, action: selectText) }
        case .annotate: if let annotate { Button(item.title, icon: item.icon, action: annotate) }
        case .share: ShareLink(item: kind == .reply ? text : CueFormat.plainText(text)) { Label(item.title, icon: item.icon) }
        case .saveAsIdea:
            if let session {
                Button(item.title, icon: item.icon) {
                    let text = text
                    workspace.attempt { try await workspace.saveReply(text, of: session) }
                }
            }
        case .editAgain: if let session { Button(item.title, icon: item.icon) { editAgain(session) } }
        case .resend:
            if let resend { Button(item.title, icon: item.icon, action: resend) }
        case .remove: if let remove { Button(item.title, icon: item.icon, role: .destructive, action: remove) }
        }
    }

    private func editAgain(_ session: SessionState) {
        let settings = workspace.services.settings
        var draft = settings.replyDraft(for: session.id)
        draft.append(stored: text)
        settings.setReplyDraft(draft, for: session.id)
    }
}
