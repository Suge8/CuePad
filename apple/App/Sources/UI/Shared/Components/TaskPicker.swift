import CueStore
import SwiftUI

/// "挂到任务"：给一条灵感挑一个任务，选中后它挂到那个任务下成为提示词（`Workspace.attach`，与拖到任务行上同一条通路，提示可撤销）。
/// 最上面"新建任务…"（建在灵感所在的项目，标题先填灵感的标题）；下面是没做完的任务，按项目分组——灵感所在项目的在前（`AttachTargets`），
/// 子任务写上它的上级；可搜。iOS 与 Mac 同一个面板，由窗口的根视图按 `Workspace.attaching` 弹出。
struct TaskPicker: View {
    let idea: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) var close
    @Environment(\.palette) var palette
    @State var groups: [TaskGroup]?
    @State var text = ""
    @State private var naming = false
    @State private var title = ""

    var body: some View {
        content
            .dialog("新建任务", isPresented: $naming, message: "这条灵感会成为它的第一条提示词", field: DialogField(prompt: "这件事是…", text: $title), buttons: [
                DialogButton(title: "取消", role: .cancel) {},
                DialogButton(title: "新建并挂上", disabled: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { createAndAttach() },
            ])
            .observing(services.store, [.cards, .projects], id: idea.id, into: $groups, onError: workspace.fail) { [idea] store in
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
            Text(workspace.catalog?.project(projectID)?.name ?? CaptureCopy.inbox)
        }
    }

    static let empty = "还没有没做完的任务，新建一个吧"

    struct Shown {
        var projectID: UUID?
        var tasks: [Card]
    }

    /// 按搜索词筛过的分组（空的组不显示）。
    var shown: [Shown] {
        let words = text.trimmingCharacters(in: .whitespaces)
        return (groups ?? []).compactMap { group in
            let tasks = words.isEmpty ? group.tasks : group.tasks.filter { $0.title.localizedCaseInsensitiveContains(words) }
            return tasks.isEmpty ? nil : Shown(projectID: group.projectID, tasks: tasks)
        }
    }

    func row(_ task: Card) -> some View {
        let parent = task.parentID.flatMap(listed)
        return Button { attach(to: task.id) } label: {
            HStack(spacing: 10) {
                // 子任务按层缩进（上级也在列表里时）；上级没列出来（搜索筛掉了）时靠下面那行"在「…」下"
                if depth(of: task) > 0 { Spacer().frame(width: CGFloat(depth(of: task)) * Self.indent) }
                TaskRingView(status: task.status, ring: .plain, done: false, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(Typography.body).foregroundStyle(palette.ink).lineLimit(2)
                    if let parent { Text("在「\(parent.title)」下").font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// 子任务每深一层缩进多少。
    private static let indent: CGFloat = 20

    private func listed(_ id: UUID) -> Card? { groups?.lazy.flatMap(\.tasks).first { $0.id == id } }

    /// 在列表里能找到的上级有几层。
    private func depth(of task: Card) -> Int {
        var depth = 0, parent = task.parentID.flatMap(listed)
        while let card = parent, depth < Card.maxDepth {
            depth += 1
            parent = card.parentID.flatMap(listed)
        }
        return depth
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
