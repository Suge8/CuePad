#if os(macOS)
import SwiftUI

/// 进展页的看板一段（`ProgressPage`）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 已完成（今天），每列是一条按列上色的泳道（`BoardColumn`、`BoardLane`），列头钉在泳道顶上、卡在下面各自滚动。
/// 项目范围同会话一段那一份（选了项目以后列头的数也只数这个项目）；"新任务"落在范围里的项目或当前项目。列从工具栏下面起、滚到它后面。
struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject)
            .padding(.horizontal, Spacing.page - 8)
            // 让在安全区里（不是内边距）：列照样滚到工具栏后面，静止时第一行在它下面隔一点
            .safeAreaPadding(.top, Bars.contentGap)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.desk)
            .animation(HandOff.quick, value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }
}
#endif
