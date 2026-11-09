#if os(iOS)
import CueStore
import SwiftUI

extension View {
    func replyNotes(session: UUID, messages: [PiChatMessage]) -> some View {
        modifier(ReplyNoteLayer(session: session, messages: messages))
    }
}

extension EnvironmentValues {
    @Entry var replyText: ReplyTextOpener?
}

/// 每次更新换出的闭包做的是同一件事，读它的回答不因此重算，所以按会话比较。
struct ReplyTextOpener: Equatable {
    let session: UUID
    let open: (UUID, ReplyTextSheet.Purpose) -> Void

    func callAsFunction(_ entry: UUID, _ purpose: ReplyTextSheet.Purpose) { open(entry, purpose) }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.session == b.session }
}

private struct ReplyNoteLayer: ViewModifier {
    let session: UUID
    let messages: [PiChatMessage]
    @Environment(AppServices.self) private var services
    @State private var opened: Opened?
    @State private var edit: ReplyNote.Edit?

    struct Opened: Identifiable {
        let entry: UUID
        let purpose: ReplyTextSheet.Purpose
        var id: UUID { entry }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                guard let id = ReplyNote.id(of: url) else { return .systemAction }
                edit = services.settings.editReplyNote(id, in: session)
                return .handled
            })
            .environment(\.replyText, ReplyTextOpener(session: session) { opened = Opened(entry: $0, purpose: $1) })
            .noteDialog($edit, session: session, order: messages.map(\.id))
            .sheet(item: $opened) { opened in
                if let message = messages.first(where: { $0.id == opened.entry }) {
                    ReplyTextSheet(message: message, purpose: opened.purpose, session: session, order: messages.map(\.id))
                }
            }
    }
}

struct ReplyTextSheet: View {
    enum Purpose { case select, annotate }

    let message: PiChatMessage
    let purpose: Purpose
    let session: UUID
    let order: [UUID]
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var edit: ReplyNote.Edit?

    var body: some View {
        let runs = MarkdownText.proseTexts(message.text)
        let notes = services.settings.replyNotes(for: session).filter { $0.entry == message.id }
        TextSheet(title: purpose == .annotate ? "批注" : "选择文本", hint: purpose == .annotate ? "选中一段，在菜单里点“批注”" : nil) {
            SelectableText(
                text: runs.joined(separator: SelectableText.runGap), ink: palette.ink,
                notes: SelectableText.Notes(
                    runs: runs, entry: message.id, marked: notes, fill: palette.selection, line: palette.signature,
                    annotate: { edit = services.settings.editReplyNote(at: $0, in: session) },
                    open: { edit = services.settings.editReplyNote($0, in: session) }))
        }
        .noteDialog($edit, session: session, order: order)
    }
}

extension View {
    fileprivate func noteDialog(_ edit: Binding<ReplyNote.Edit?>, session: UUID, order: [UUID]) -> some View {
        modifier(NoteDialog(edit: edit, session: session, order: order))
    }
}

private struct NoteDialog: ViewModifier {
    @Binding var edit: ReplyNote.Edit?
    let session: UUID
    let order: [UUID]
    @Environment(AppServices.self) private var services
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .dialog(
                "批注", isPresented: Binding { edit != nil } set: { if !$0 { edit = nil } },
                message: edit.map { "「\(ReplyNote.excerpt($0.note.quote))」" },
                field: DialogField(prompt: "写批注，随下一句发出", text: $text), buttons: edit.map(buttons) ?? [])
            .onChange(of: edit) { text = edit?.note.note ?? "" }
    }

    private var written: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 记下时读此刻的字（按钮建好之后还在打字）。
    private func buttons(_ edit: ReplyNote.Edit) -> [DialogButton] {
        let settings = services.settings, session = session, order = order
        let save = DialogButton(title: edit.fresh ? "添加" : "完成", disabled: written.isEmpty) {
            settings.save(edit, text: written, order: order, in: session)
        }
        let cancel = DialogButton(title: "取消", role: .cancel) {}
        guard !edit.fresh else { return [cancel, save] }
        return [DialogButton(title: "删除", role: .destructive) { settings.removeReplyNote(edit.note.id, in: session) }, cancel, save]
    }
}
#endif
