#if os(iOS)
import CueStore
import SwiftUI

/// 编辑一条任务的内容（任务页与项目页的长按"编辑"共用）。保存写入成功才收起；失败时留在这里、
/// 已改的文字不丢，原因显示在输入框下面。
struct TaskEditSheet: View {
    let task: CueTask
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var saving = false
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("任务", text: $text, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } footer: {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.failure)
                    }
                }
                .listRowBackground(palette.paper)
            }
            .deskBackground()
            .navigationTitle("编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(trimmed.isEmpty || saving)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(saving)
        .onAppear {
            text = task.content
            focused = true
        }
    }

    private func save() {
        let content = trimmed, id = task.id
        guard !content.isEmpty, !saving else { return }
        guard content != task.content else { dismiss(); return }
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                try await workspace.services.store.updateTask(id) { $0.content = content }
                dismiss()
            } catch {
                failure = "没能保存：\(error.localizedDescription)"
            }
        }
    }
}
#endif
