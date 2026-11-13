#if os(iOS)
import CueStore
import SwiftUI

struct ProgressScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.underCue) private var under
    @Environment(\.headInset) private var inset
    @State private var board: TaskBoard?

    var body: some View {
        page
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    /// 宽屏同 Mac 的 `TaskBoardPage`：不要页头，四个列头就是最顶那一排，范围钮在它们开头；额度在会话条最下一排（`WideRail`）。
    @ViewBuilder private var page: some View {
        if workspace.layout == .wide {
            boardView
                .padding(.leading, inset.leading + Chrome.control + Spacing.item - BoardCardMetrics.inset)
                .padding(.trailing, under > 0 ? 0 : inset.trailing - BoardCardMetrics.inset)
                .overlay(alignment: .topLeading) {
                    ProjectScopeButton().padding(.leading, inset.leading).padding(.top, BoardCardMetrics.inset)
                }
                // 列头离列的上沿有一圈：整块上提这一圈，列头与会话条顶上那一排钮同一条中线
                .padding(.top, -BoardCardMetrics.inset)
                // 最顶那一排就是玻璃列头，系统在状态栏下垫的那层雾会把它们盖淡
                .scrollEdgeEffectHidden(true, for: .top)
                .navigationTitle(Text("进展"))
        } else {
            boardView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .floatingHeader("进展")
        }
    }

    private var boardView: some View {
        let scope = workspace.scopedProject
        let shown = (board ?? .empty).only(scope)
        let adding = Bindable(workspace).addsTask
        return Group {
            if verticalSizeClass == .compact || sizeClass == .regular {
                BoardColumns(board: shown, adding: adding, newTaskProject: newTaskProject, margin: workspace.layout == .wide ? 0 : 12, tail: under)
            } else {
                PhoneBoard(board: shown, adding: adding, newTaskProject: newTaskProject)
            }
        }
        // 换范围不带里层的挪位与数字动画，理由同 Mac 的 `TaskBoardPage`
        .transaction(value: scope) { $0.disablesAnimations = true }
    }

    private var newTaskProject: UUID? { workspace.scopedProject ?? workspace.currentProject }
}
#endif
