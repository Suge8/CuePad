import CueStore
import SwiftUI

/// Cue 页说出去的是一句普通的话"关于「标题」：……"（Cue 的输入框没有批注）。
struct PreviewReplyBar: View {
    let reply: PreviewReply
    let preview: PreviewItem
    let about: String
    let entry: UUID?
    let done: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()

    var body: some View {
        switch reply {
        case .cue: field(String(localized: "关于「\(about)」对 \(workspace.cue.name) 说…"), to: .cue).glass(in: .rect(cornerRadius: Radius.field))
        case .session(let session): quote(in: session)
        case .answer(let message): choices(message).glass(in: .rect(cornerRadius: Radius.field))
        }
    }

    @ViewBuilder private func quote(in session: SessionState) -> some View {
        if let entry {
            Button("回复", icon: .reply) {
                workspace.quote(preview, in: entry, of: session)
                done()
            }
            .buttonStyle(ControlButtonStyle(kind: .glass))
            .accessibilityHint("回复框带上这一份的引用")
            .help("回复框带上这一份的引用")
        }
    }

    private func field(_ prompt: String, to listener: Listener) -> some View {
        let empty = text.isEmpty
        return HStack(spacing: Spacing.item) {
            TextField(prompt, text: $draft.text, palette: palette)
                .textFieldStyle(.plain).font(Typography.body)
                .submitLabel(.send)
                .onSubmit { send(to: listener) }
            Button { send(to: listener) } label: { SendGlyph(empty ? .idle : .ready) }
                .buttonStyle(PressStyle(.button))
                .disabled(empty)
                .accessibilityLabel("发送")
        }
        .padding(.leading, Spacing.block).padding(.trailing, Spacing.item).frame(minHeight: ComposerMetrics.slot)
    }

    private var text: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(to listener: Listener) {
        guard !text.isEmpty else { return }
        let line = String(localized: "关于「\(about)」：\(text)")
        workspace.speak(to: listener, from: $draft, content: { _ in line })
        done()
    }

    private func choices(_ message: CueMessage) -> some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            CueQuestionLine(message: message)
            CueChoices(message: message) { option in
                workspace.attempt { try await workspace.services.answerCueQuestion(message.id, option) }
                done()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
