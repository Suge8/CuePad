import CueStore
import SwiftUI

/// Cue 页说出去的是一句普通的话"关于「标题」：……"（Cue 的输入框没有批注）。
/// 会话里点"回复"不关预览：那颗钮原地变成只写给这一份的一行，写的话记成这一份的批注（`AppSettings.annotate`），随会话的下一句发出；
/// 收起后钮上就是那句话，再点接着改。不把会话的回复框搬进来：里面别的草稿与批注和这一份摆在一起，分不出这句话是回哪一份的。
struct PreviewReplyBar: View {
    let reply: PreviewReply
    let preview: PreviewItem
    let about: String
    let entry: UUID?
    let done: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ComposerDraft()
    @State private var writing = false

    var body: some View {
        switch reply {
        case .cue: field(String(localized: "关于「\(about)」对 \(workspace.cue.name) 说…"), to: .cue).glass(in: .rect(cornerRadius: Radius.field))
        case .session(let session): note(in: session)
        case .answer(let message): choices(message).glass(in: .rect(cornerRadius: Radius.field))
        }
    }

    @ViewBuilder private func note(in session: SessionState) -> some View {
        if let entry {
            let settings = workspace.services.settings
            let said = settings.replyNotes(for: session.id).first { $0.preview == preview.id }?.note ?? ""
            ZStack(alignment: .bottom) {
                if writing {
                    PreviewNoteField(prompt: String(localized: "批注这一份"), text: said) {
                        settings.annotate(preview, $0, in: entry, for: session.id)
                    } done: { fold(true) }
                        // 翻到下一份时这一份的先记下、收起
                        .id(preview.id)
                        #if os(macOS)
                        // 点外面与 Esc 先收起这一行，再按一次才关预览
                        .grownInPlace(isPresented: $writing) { fold(true) }
                        #endif
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else {
                    Group {
                        if said.isEmpty { Button("回复", icon: .reply) { fold(false) } } else { Button(said, icon: .reply) { fold(false) } }
                    }
                    .lineLimit(1).frame(maxWidth: 360)
                    .buttonStyle(ControlButtonStyle(kind: .glass))
                    .accessibilityHint("批注这一份，随下一句发出")
                    .help("批注这一份，随下一句发出")
                    .transition(.opacity)
                }
            }
            .onChange(of: preview.id) { writing = false }
        }
    }

    private func fold(_ folded: Bool) {
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade) { writing = !folded }
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

/// 怎么收起都记下（回车、交出键盘、点外面、翻页、关预览）：写了一半的话不丢。
private struct PreviewNoteField: View {
    let prompt: String
    @State var text: String
    let keep: (String) -> Void
    let done: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            TextField(prompt, text: $text, palette: palette)
                .textFieldStyle(.plain).font(Typography.body)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(done)
            Button(action: done) { SendGlyph(.save(enabled: true)) }
                .buttonStyle(PressStyle(.button))
                .accessibilityLabel("记下")
        }
        .padding(.leading, Spacing.block).padding(.trailing, Spacing.item).frame(minHeight: ComposerMetrics.slot)
        .glass(in: .rect(cornerRadius: Radius.field))
        .onAppear { focused = true }
        .onChange(of: focused) { if !focused { done() } }
        .onDisappear { keep(text) }
    }
}
