import CueStore
import SwiftUI

/// 全屏预览底部的玻璃栏（`PreviewReply`）：对 Cue 或这个会话说一句关于这一份的话，或回答拍板。
/// 说出去的就是一句普通的话"关于「标题」：……"，走说话的那一条路（`Workspace.speak`），Cue 与会话都看得懂，不另造格式；
/// 回答走拍板的那一条（`answerCueQuestion`）。说完、答完就收起全屏页，回到对话里看自己那句。
struct PreviewReplyBar: View {
    let reply: PreviewReply
    /// 当前这一份的标题
    let about: String
    let done: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()

    var body: some View {
        Group {
            switch reply {
            case .cue: field(String(localized: "关于「\(about)」对 \(workspace.cue.name) 说…"), to: .cue)
            case .session(let session): field(String(localized: "关于「\(about)」对会话说…"), to: .session(session, mode: .send))
            case .answer(let message): choices(message)
            }
        }
        .glass(in: .rect(cornerRadius: Radius.field))
    }

    private func field(_ prompt: String, to listener: Listener) -> some View {
        let empty = text.isEmpty
        return HStack(spacing: 8) {
            // 一行：回车就发（多行的输入框回车是换行），长话照样横着滚
            TextField(prompt, text: $draft.text, palette: palette)
                .textFieldStyle(.plain).font(Typography.body)
                .submitLabel(.send)
                .onSubmit { send(to: listener) }
            Button { send(to: listener) } label: { SendGlyph(empty ? .idle : .ready) }
                .buttonStyle(PressStyle(.button))
                .disabled(empty)
                .accessibilityLabel("发送")
        }
        .padding(.leading, 18).padding(.trailing, 8).frame(minHeight: ComposerMetrics.slot)
    }

    private var text: String { draft.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(to listener: Listener) {
        guard !text.isEmpty else { return }
        let line = String(localized: "关于「\(about)」：\(text)")
        workspace.speak(to: listener, from: $draft, content: { _ in line })
        done()
    }

    private func choices(_ message: CueMessage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CueQuestionLine(message: message)
            CueChoices(message: message) { option in
                workspace.attempt { try await workspace.services.answerCueQuestion(message.id, option) }
                done()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
