#if os(macOS)
import SwiftUI

/// 任务页（侧栏"任务"、⌘⇧T）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 已完成（今天），列不按状态铺色。
/// 顶上不写页名（侧栏的选中格已经说了），也不另起一排：四个列头就排在窗口最顶那一排里、各对齐自己那一列（`boardTopRow`），卡各自滚动、从它们下面过。
/// 这一页的操作都在右上的"⋯"（`PageMenuSlot`）：新任务（落在范围里的项目或当前项目）、项目范围（同会话页那一份；选了项目以后列头的数也只数这个项目）、
/// 搜索（⌘K）、全部归档做完的。
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
            // 页的上沿就是窗口最顶那一排的下沿：量一次给列头排进那一排
            Color.clear.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { band = $0 }
            BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject)
                .padding(.horizontal, Spacing.page - 8)
                .environment(\.boardBand, band)
                .ignoresSafeArea(edges: .top)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.desk)
            .animation(HandOff.quick, value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }
}
#endif
