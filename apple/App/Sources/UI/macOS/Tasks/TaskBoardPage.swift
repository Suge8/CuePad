#if os(macOS)
import SwiftUI

/// 任务页（侧栏"任务"、⌘⇧T）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 已完成（今天），每列各自滚动（`BoardColumn`），列头随列一起滚。
/// 顶上不写页名（侧栏的选中格已经说了），顶上那一排（`pageHeader`）左边是项目范围（`ProjectScopeMenu`，同会话页那一份；选了项目以后列头的数也只数这个项目）、
/// 右边"新任务"（落在范围里的项目或当前项目）。
struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject)
            .padding(.horizontal, Spacing.page - 8)
            .pageHeader { topRow }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.desk)
            .animation(Motion.quick, value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    private var topRow: some View {
        HStack(spacing: 16) {
            ProjectScopeMenu()
            Spacer(minLength: 0)
            Button("新任务", icon: .add) { workspace.addsTask.toggle() }
                .buttonStyle(ControlButtonStyle(kind: .glass))
                .help("在待办里添加任务")
        }
    }
}
#endif
