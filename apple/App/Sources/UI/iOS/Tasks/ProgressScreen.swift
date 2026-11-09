#if os(iOS)
import CueStore
import SwiftUI

struct ProgressScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?

    var body: some View {
        boardView
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .floatingHeader("进展", center: { ProgressHeader() }) { EmptyView() }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: workspace.addsTask)
            .onChange(of: workspace.scopedProject) { workspace.addsTask = false }
            .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    private var boardView: some View {
        let scope = workspace.scopedProject
        let shown = (board ?? .empty).only(scope)
        let adding = Bindable(workspace).addsTask
        return Group {
            if verticalSizeClass == .compact || sizeClass == .regular {
                BoardColumns(board: shown, adding: adding, newTaskProject: newTaskProject, margin: 12)
            } else {
                PhoneBoard(board: shown, adding: adding, newTaskProject: newTaskProject)
            }
        }
        // 换范围不带里层的挪位与数字动画，理由同 Mac 的 `TaskBoardPage`
        .transaction(value: scope) { $0.disablesAnimations = true }
    }

    private var newTaskProject: UUID? { workspace.scopedProject ?? workspace.currentProject }
}

struct ProgressHeader: View {
    @State private var open = DebugHooks.preset.quotaOpen

    var body: some View {
        HStack(spacing: 0) {
            ProjectScope()
            QuotaRings(open: open, height: FloatingHeaderLayout.height) { open.toggle() }
                .popup(isPresented: $open) { QuotaDetail().padding(Spacing.panel) }
                .refreshesQuota(open: open)
        }
        .headerPiece()
    }
}

#endif
