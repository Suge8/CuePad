#if os(macOS)
import SwiftUI

/// 进展页的看板一段（`ProgressPage`）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 已完成（今天），列不按状态铺色。
/// 不另起一排：四个列头就排在窗口最顶那一排里、各对齐自己那一列（`boardTopRow`），卡各自滚动、从它们下面过。
/// 项目范围同会话一段那一份（选了项目以后列头的数也只数这个项目）；"新任务"落在范围里的项目或当前项目。
struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?
    /// 窗口最顶那一排的高（`boardBand`）。
    @State private var band: CGFloat = 0

    var body: some View {
        let scope = workspace.scopedProject
        ZStack(alignment: .topLeading) {
            BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject, margin: Spacing.page - 8)
                .environment(\.boardBand, band)
                .ignoresSafeArea(edges: .top)
                // 换范围是整块换内容：列里按卡挪位的动画与列头数字滚动都不跟着走（跟着走时四列每帧重排、数字每帧在 CPU 上重画，掉帧半秒）。
                // `animation = nil` 挡不住里层的 `.animation(_:value:)`，只有 `disablesAnimations` 挡得住
                .transaction(value: scope) { $0.disablesAnimations = true }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .readsTopBand(into: $band)
            .background(palette.desk)
            .animation(HandOff.quick, value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }
}
#endif
