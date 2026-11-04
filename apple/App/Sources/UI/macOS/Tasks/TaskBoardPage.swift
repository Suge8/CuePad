#if os(macOS)
import SwiftUI

/// 进展页（项目｜进展的"进展"、⌘⇧T）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 已完成（今天），列不按状态铺色。
/// 宽屏没有会话一段：在跑与等你的会话都在看板上，已结束的在会话条的"更早"。
/// 四个列头就是窗口最顶那一排（`boardTopRow`，与红绿灯同一中线），卡各自滚动、从列头下面过；那一排右端是主区栏头的同步提醒与"⋯"（`MainColumn`），看板右边让出它们。
/// 项目范围收在"⋯"里（选了项目以后列头的数也只数这个项目，"⋯"角上带它的小图形）；待办列头的 ＋ 添加任务，落在范围里的项目或当前项目。
struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @State private var board: TaskBoard?

    private static let margin = Spacing.page - 8

    /// 看板右边让出栏头右端那几颗钮：同步提醒（有同步时常驻一格，`SyncAlertSlot`）、"⋯"与它前面的一道缝，再与最后一列隔一截。
    private var trailing: CGFloat {
        let menu = Spacing.toolbarGap + ControlMetrics.height + (services.sync == nil ? 0 : ControlMetrics.height)
        return max(0, inset.trailing + menu + 12 - Self.margin)
    }

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject, margin: Self.margin)
            .padding(.trailing, trailing)
            .environment(\.boardBand, WideMetrics.band)
            // 换范围是整块换内容：列里按卡挪位的动画与列头数字滚动都不跟着走（跟着走时四列每帧重排、数字每帧在 CPU 上重画，掉帧半秒）。
            // `animation = nil` 挡不住里层的 `.animation(_:value:)`，只有 `disablesAnimations` 挡得住
            .transaction(value: scope) { $0.disablesAnimations = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.desk)
            .animation(Motion.fade, value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }
}
#endif
