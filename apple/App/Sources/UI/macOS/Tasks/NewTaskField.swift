#if os(macOS)
import CueStore
import SwiftUI

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。`parent` 给了时建成它的一个步骤（任务浮窗里）；`choosesProject` 时右边可换落到哪个项目（任务面板跨项目）。
struct NewTaskField: View {
    let project: UUID?
    var parent: UUID?
    var choosesProject = false
    /// 出现时光标就在这一行（任务面板：从"新建任务"打开后直接写）。
    var autofocus = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosen: UUID??
    @FocusState private var focused: Bool

    private var target: UUID? { chosen ?? project }
    private var prompt: String { parent == nil ? "添加任务" : "添加步骤" }

    var body: some View {
        HStack(spacing: TaskMetrics.columnGap) {
            // 入口不用系统占位灰：那样看起来像不能点
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                .frame(width: TaskMetrics.ringColumn)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(palette.ink2)) { Text(prompt) }.textFieldStyle(.plain).font(Typography.body)
                .accessibilityLabel(prompt)
                .focused($focused)
                .onSubmit(add)
            if choosesProject, let projects = workspace.catalog?.projects, !projects.isEmpty {
                Menu {
                    Button(CaptureCopy.unfiled) { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 10)
                        Text(current?.name ?? CaptureCopy.unfiled).lineLimit(1)
                    }
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(palette.fill, in: .capsule)
                    .contentShape(.capsule)
                }
                .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? CaptureCopy.unfiled)")
            }
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        .onAppear { focused = autofocus }
    }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        if let parent {
            let store = workspace.services.store
            workspace.attempt { _ = try await store.createTask(content, under: parent) }
        } else {
            let project = target
            workspace.attempt { _ = try await workspace.createTask(content, in: project) }
        }
    }
}

#endif
