#if os(macOS)
import SwiftUI

struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under
    @State private var board: TaskBoard?

    /// 滚动区的边就是两端列的边，看板里不另留页边（`margin: 0`）：放不下横滑时，滚过去的列画到滚动区的边为止，
    /// 页边留在滚动区里面的话，列会滑进栏头左右那几颗钮底下（#86）。
    /// Cue 浮着时右边不留这条边：滚动区铺到浮板下面（`tail`），列滑到浮板后面，不在桌面上凭空切断。
    private var trailing: CGFloat {
        let alert = SyncAlertSlot.needed(services) ? Spacing.item + ControlMetrics.height : 0
        return (under > 0 ? 0 : inset.trailing - BoardCardMetrics.inset) + alert
    }

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject, margin: 0, tail: under > 0 ? under + trailing : 0)
            .padding(.trailing, under > 0 ? 0 : trailing)
            .padding(.leading, WideMetrics.boardLead(inset))
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
