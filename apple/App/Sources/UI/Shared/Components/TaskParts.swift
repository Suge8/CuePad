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

/// 任务的标题（单行），就地改、自动保存。回车结束编辑。
struct TaskHeading: View {
    let task: Card
    let font: Font
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var title = ""
    @State private var autosave: Autosave?
    @FocusState private var focused: Bool

    var body: some View {
        TextField("这件事是…", text: $title, palette: palette, axis: .vertical)
            .font(font).foregroundStyle(task.status == .done ? palette.ink3 : palette.ink)
            .lineLimit(1...3).focused($focused)
            .onChange(of: title) { _, next in
                // 标题只有一行：回车结束编辑
                if next.contains("\n") { title = next.replacingOccurrences(of: "\n", with: ""); focused = false }
                save()
            }
            .textFieldStyle(.plain)
            .onAppear {
                title = task.heading
                let store = services.store, id = task.id
                autosave = Autosave(
                    save: { title in try await store.updateCard(id) { $0.body = CueLines.joined(title: title, rest: $0.rest) } }, onError: workspace.fail)
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
