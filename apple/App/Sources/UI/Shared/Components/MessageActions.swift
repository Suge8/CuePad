import CueStore
import CueText
import SwiftUI

/// 有哪几项、什么顺序只在 `MessageMenu`，这里只画。只属于某一行的动作（选择文本、批注、重发、移除）由那一行给。
/// `text`：你的话是存储格式正文（复制与存为灵感连图片一起；分享只给文字），Pi 与 Cue 的回答是 Markdown。
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

    /// 草稿只有一份（`AppSettings.replyDraft`）：已经写了字就接在后面，不覆盖。
    private func editAgain(_ session: SessionState) {
        let settings = workspace.services.settings
        var draft = settings.replyDraft(for: session.id)
        draft.append(stored: text)
        settings.setReplyDraft(draft, for: session.id)
    }
}
