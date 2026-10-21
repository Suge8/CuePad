import CueStore
import CueText
import SwiftUI


// 任务气泡（`TaskBubble`）的几块：任务是一件要做成的事——标题（`TaskHeading`）与下面要交代给 Agent 的话（正文，`Card.rest`）。


/// 编辑器写的是正文的哪一段：整条（灵感），或任务标题下面的话（`Card.rest`；标题由 `TaskHeading` 另写，写入时各读库里此刻的另一段）。
nonisolated enum CardTextPart: Sendable {
    case whole, rest

    func text(of card: Card) -> String { self == .whole ? card.body : card.rest ?? "" }

    func write(_ text: String, into card: inout Card) {
        switch self {
        case .whole: card.body = text
        case .rest: card.rest = text
        }
    }
}

/// 点了才换成输入框的那一下先让窗口交出键盘：别的输入框（Mac 的"随手记"是 AppKit 文字区）还拿着键盘时，
/// SwiftUI 接不过来，焦点停在窗口上、打的字没处去（真实点按实测）。
func releaseKeyboard() {
    #if os(macOS)
    NSApp.keyWindow?.makeFirstResponder(nil)
    #endif
}

/// 任务的标题（单行），就地改、自动保存。回车结束编辑。
/// 点之前只是一段字，点了才换成输入框、接过键盘：系统的输入框建一次不便宜（打开任务气泡那一帧里最贵的一块），标题又是看得多、改得少。
/// 点过就一直是输入框：刚写的字还没从库里读回来，换回字会闪一下旧标题。
struct TaskHeading: View {
    let task: Card
    let font: Font
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var autosave: Autosave?
    @FocusState private var focused: Bool
    @State private var editing = false

    var body: some View {
        if editing { field } else {
            let empty = task.heading.isEmpty
            Button {
                releaseKeyboard()
                title = task.heading
                editing = true
            } label: {
                Text(empty ? Self.prompt : task.heading)
                    .font(font).foregroundStyle(empty || task.status == .done ? palette.ink3 : palette.ink)
                    .lineLimit(Self.lines).frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint("改标题")
        }
    }

    private static let prompt = "这件事是…"
    private static let lines = 3

    private var field: some View {
        TextField(Self.prompt, text: $title, palette: palette, axis: .vertical)
            .font(font).foregroundStyle(task.status == .done ? palette.ink3 : palette.ink)
            .lineLimit(1...Self.lines).focused($focused)
            .onChange(of: title) { _, next in
                // 标题只有一行：回车结束编辑
                if next.contains("\n") { title = next.replacingOccurrences(of: "\n", with: ""); focused = false }
                save()
            }
            .textFieldStyle(.plain)
            .onAppear {
                let store = services.store, id = task.id
                autosave = Autosave(
                    save: { title in try await store.updateCard(id) { $0.body = CueLines.joined(title: title, rest: $0.rest) } }, onError: workspace.fail)
            }
            // 换成输入框的那一帧还没进窗口的响应链：下一帧再接键盘
            .task {
                await NextFrame.wait()
                focused = true
                #if os(macOS)
                // 接过键盘时系统输入框全选了标题：光标放到末尾，同点进一段字（一敲键就整句换掉太容易误伤）
                await NextFrame.wait()
                (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil)
                #endif
            }
            .onDisappear { if let autosave { Task { await autosave.flush() } } }
    }

    /// 只换标题那一行：下面的正文在写入的那一刻从库里读（`Card.rest`），与正文编辑各写各的。
    private func save() {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != task.heading else { return }
        autosave?.changed(title)
    }
}
