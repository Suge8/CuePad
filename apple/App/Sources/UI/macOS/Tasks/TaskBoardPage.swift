#if os(macOS)
import SwiftUI

/// 进展页（项目｜进展的"进展"、⌘⇧T）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 已完成（今天），列不按状态铺色。
/// 会话不另成一段：在跑与等你的会话都在看板上，已结束的在会话条的"更早"。
/// 四个列头就是窗口最顶那一排（`boardTopRow`，与红绿灯同一中线），卡各自滚动、从列头下面过；那一排右端是主区栏头的同步提醒与"⋯"（`MainColumn`），看板右边让出它们。
/// 项目范围收在"⋯"里（选了项目以后列头的数也只数这个项目，"⋯"角上带它的小图形）；待办列头的 ＋ 添加任务、推进中列头的 ＋ 开新会话（`LaneAdd`），
/// 都落在范围里的项目或当前项目。
struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.headInset) private var inset
    @State private var board: TaskBoard?

    /// 看板两侧页边：再加卡离列边的 `BoardCardMetrics.inset`，卡与列头的左沿正好在栏边 `Spacing.page` 上（同栏头、同别的页）。
    static let margin = Spacing.page - BoardCardMetrics.inset

    /// 看板右边让出最顶那一排末尾的"⋯"（列头与它同一排）：钮前那道缝与圆钮——栏头右边距与看板的页边、卡离列边加起来一样多，抵掉了。
    private static let menu = Spacing.item + ControlMetrics.height

    /// 看板右边让出栏头右端那几颗钮："⋯"（`menu`，收起的 Cue 钮压在这一排时多让它那一截），同步要你关注时它左边再多一颗提醒（`SyncAlertSlot`，这一页不常驻）。
    private var trailing: CGFloat {
        let alert = SyncAlertSlot.needed(services) ? Spacing.item + ControlMetrics.height : 0
        return inset.trailing - Spacing.page + Self.menu + alert
    }

    var body: some View {
        let scope = workspace.scopedProject
        BoardColumns(board: (board ?? .empty).only(scope), adding: Bindable(workspace).addsTask, newTaskProject: scope ?? workspace.currentProject, margin: Self.margin)
            .padding(.trailing, trailing)
            .environment(\.boardBand, Chrome.band)
            .environment(\.laneAddsTask, { workspace.addsTask = true })
            .environment(\.laneAddsSession, { workspace.openNewSession(in: scope) })
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
