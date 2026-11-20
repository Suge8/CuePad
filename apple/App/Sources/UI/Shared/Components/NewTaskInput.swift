import CueStore
import SwiftUI

/// 看板上记任务只有这一个输入框（待办的"＋"），同新会话的输入框一张卡、一种呈现（`NewSessionInput`）：去处胶囊在上，
/// 字在中间（第一行是标题，其余是正文，同任务正文），"添加"在右下。记下一条就清空、留着接着记；收起只有 Esc 与点外面。
struct NewTaskInput: View {
    let start: TaskStart
    @Environment(Workspace.self) private var workspace
    @State private var project: UUID?
    @State private var draft = ComposerDraft()
    @FocusState private var focused: Bool

    private var target: UUID { project ?? start.project }
    private var empty: Bool { draft.isEmpty(accepting: []) }

    var body: some View {
        Composer(
            draft: $draft, prompt: "写下任务", label: "添加任务", focus: $focused, accepts: [], tooled: true, pill: true,
            shortcuts: [.send: add],
            header: {
                HStack(spacing: Spacing.item) {
                    DestinationMenu(project: target, lead: Text("记到")) { project = $0 }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.group).padding(.top, Spacing.item)
            },
            tools: { EmptyView() },
            send: {
                Button("添加", action: add)
                    .buttonStyle(ControlButtonStyle(kind: .primary, size: .compact)).disabled(empty)
            })
        #if os(macOS)
        .frame(width: BubbleMetrics.width)
        .task {
            // 浮层出现的那一帧文字区还没进窗口的响应链：下一帧再接键盘
            await NextFrame.wait()
            focused = true
        }
        #else
        .onAppear { focused = true }
        #endif
    }

    private func add() {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines), project = target
        guard !text.isEmpty else { return }
        draft = ComposerDraft()
        workspace.attempt {
            do {
                _ = try await workspace.createTask(text, in: project)
            } catch {
                // 没记下：字放回去，这期间新打的接在后面
                draft.text = draft.text.isEmpty ? text : text + "\n" + draft.text
                throw error
            }
        }
    }
}

/// 开着的记任务输入框（`Workspace.newTask`）：记到哪个项目，打开时取看板的项目范围，没有范围取当前项目。
struct TaskStart: Identifiable {
    let id = UUID()
    let project: UUID
}

extension Workspace {
    func openNewTask() {
        newTask = TaskStart(project: scopedProject ?? currentProject ?? Project.defaultID)
    }
}
