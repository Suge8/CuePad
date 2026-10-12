import CueStore
import SwiftUI

/// "挂到任务"：给一条灵感挑一个任务，选中后它挂到那个任务下成为提示词（`Workspace.attach`，与拖到任务行上同一条通路，提示可撤销）。
/// 最上面"新建任务…"（建在灵感所在的项目，标题先填灵感的标题）；下面是没做完的任务，按项目分组——灵感所在项目的在前（`AttachTargets`），
/// 可搜。iOS 与 Mac 同一个面板，由窗口的根视图按 `Workspace.attaching` 弹出。
struct TaskPicker: View {
    let idea: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) var close
    @Environment(\.palette) var palette
    @State var groups: [AttachTargets.Group]?
    @State var text = ""
    @State private var naming = false
    @State private var title = ""

    var body: some View {
        content
            .dialog("新建任务", isPresented: $naming, message: "这条灵感会成为它的第一条提示词", field: DialogField(prompt: "这件事是…", text: $title), buttons: [
                DialogButton(title: "取消", role: .cancel) {},
                DialogButton(title: "新建并挂上", disabled: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { createAndAttach() },
            ])
            .observing(services.store, id: idea.id, into: $groups, onError: workspace.fail) { [idea] store in
                try AttachTargets.read(for: idea, from: store)
            }
    }

    var newTask: some View {
        Button {
            title = idea.title
            naming = true
        } label: {
            Label("新建任务…", systemImage: "plus").foregroundStyle(palette.ink).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    func header(_ projectID: UUID?) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: workspace.catalog?.project(projectID), size: 12)
            Text(workspace.catalog?.project(projectID)?.name ?? CaptureCopy.unfiled)
        }
    }

    static let empty = "还没有没做完的任务，新建一个吧"

    /// 按搜索词筛过的分组（空的组不显示）。
    var shown: [AttachTargets.Group] {
        let words = text.trimmingCharacters(in: .whitespaces)
        return (groups ?? []).compactMap { group in
            let tasks = words.isEmpty ? group.tasks : group.tasks.filter { $0.title.localizedCaseInsensitiveContains(words) }
            return tasks.isEmpty ? nil : AttachTargets.Group(projectID: group.projectID, tasks: tasks)
        }
    }

    func row(_ task: Card) -> some View {
        Button { attach(to: task.id) } label: {
            HStack(spacing: 10) {
                TaskRingView(status: task.status, ring: .plain, done: false, size: 16)
                Text(task.title).font(Typography.body).foregroundStyle(palette.ink).lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func attach(to task: UUID) {
        let id = idea.id
        close()
        workspace.attempt { try await workspace.attach(id, to: task) }
    }

    private func createAndAttach() {
        let id = idea.id, title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        close()
        workspace.attempt { try await workspace.attachToNewTask(id, title: title) }
    }
}
