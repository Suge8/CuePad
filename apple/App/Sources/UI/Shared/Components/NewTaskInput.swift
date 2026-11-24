import CueStore
import SwiftUI

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
            draft: $draft, prompt: "写下任务", label: "添加任务", focus: $focused, accepts: [],
            submit: add,
            header: {
                HStack(spacing: Spacing.item) {
                    DestinationMenu(project: target, lead: Text("记到")) { project = $0 }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.group).padding(.top, Spacing.item)
            },
            tools: { EmptyView() },
            send: {
                Button(action: add) { SendGlyph(.save(enabled: !empty)) }
                    .buttonStyle(PressStyle(.button)).disabled(empty).accessibilityLabel("添加")
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
                draft.text = draft.text.isEmpty ? text : text + "\n" + draft.text
                throw error
            }
        }
    }
}

struct TaskStart: Identifiable {
    let id = UUID()
    let project: UUID
}

extension Workspace {
    func openNewTask() {
        newTask = TaskStart(project: scopedProject ?? currentProject ?? Project.defaultID)
    }
}
