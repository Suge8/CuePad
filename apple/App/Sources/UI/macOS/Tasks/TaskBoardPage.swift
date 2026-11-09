#if os(macOS)
import SwiftUI

struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @State private var board: TaskBoard?

    static let margin = Spacing.page - BoardCardMetrics.inset

    /// 栏头右边距与看板的页边、卡离列边加起来一样多，抵掉了。
    private static let menu = SearchSlot.reserve + Spacing.item + ControlMetrics.height

    private var trailing: CGFloat {
        let alert = SyncAlertSlot.needed(services) ? Spacing.item + ControlMetrics.height : 0
        return inset.trailing - Spacing.page + Self.menu + alert
    }

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject, margin: Self.margin)
            .padding(.trailing, trailing)
            .padding(.leading, inset.leading - Spacing.page)
            .environment(\.boardBand, Chrome.band)
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
