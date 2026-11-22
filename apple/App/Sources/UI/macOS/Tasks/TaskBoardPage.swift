#if os(macOS)
import SwiftUI

struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under
    @State private var board: TaskBoard?

    private var trailing: CGFloat {
        let alert = SyncAlertSlot.needed(services) ? Spacing.item + ControlMetrics.height : 0
        return (under > 0 ? 0 : inset.trailing - BoardCardMetrics.inset) + alert
    }

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), margin: 0, tail: under > 0 ? under + trailing : 0)
            .padding(.trailing, under > 0 ? 0 : trailing)
            .padding(.leading, WideMetrics.boardLead(inset))
            .environment(\.boardBand, Chrome.band)
            // 换范围是整块换内容：列里按卡挪位的动画与列头数字滚动都不跟着走（跟着走时四列每帧重排、数字每帧在 CPU 上重画，掉帧半秒）。
            // `animation = nil` 挡不住里层的 `.animation(_:value:)`，只有 `disablesAnimations` 挡得住
            .transaction(value: scope) { $0.disablesAnimations = true }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(palette.desk)
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }
}
#endif
