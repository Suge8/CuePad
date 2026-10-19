#if os(iOS)
import CueStore
import SwiftUI

extension View {
    /// 会话页的批注层（手机）：回答的长按菜单里"选择文本"与"批注"打开同一张可选文本页（`ReplyTextSheet`），在那里选一段、
    /// 系统编辑菜单里点"批注"写一句，进这个会话回复框的草稿（`AppSettings.replyNotes`），随下一句发出（`ReplyNote`）。
    /// 点对话里的高亮直接弹出改那一条的提示框。增删改的规则与 Mac 同一套（`AppSettings.editReplyNote`）。
    func replyNotes(session: UUID, messages: [PiChatMessage]) -> some View {
        modifier(ReplyNoteLayer(session: session, messages: messages))
    }
}

extension EnvironmentValues {
    /// 打开一条回答的可选文本页（会话页的批注层给）；不在会话页里为 nil。
    @Entry var replyText: ReplyTextOpener?
}

/// 按会话比较（同 `ChatJump`）：每次更新换出的闭包做的是同一件事，读它的回答不因此重算。
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

/// 一条回答的可选文本页：正文是渲染后的可选文字（`MarkdownText.proseTexts`，段间空一行），选区才换算得成批注的位置；
/// 系统编辑菜单最前面是"批注"（跨段的选区截到起点那一段），批注过的几处同对话里一样高亮，点它改或删那一条。
/// "选择文本"与"批注"打开的是这同一页，只是标题与提示不同。
struct ReplyTextSheet: View {
    enum Purpose { case select, annotate }

    let message: PiChatMessage
    let purpose: Purpose
    let session: UUID
    /// 对话里回答的 id 顺序：新的批注按它排进草稿。
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
    /// 写或改一条批注的系统提示框：标题"批注"，消息是摘录，输入框里是批注；空的不能记下，已有的那条另给"删除"。
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
