#if os(iOS)
import CueStore
import SwiftUI

/// 进展页（窄屏侧栏与宽屏主区的"进展"）：只有看板，只看项目范围里的（`Workspace.scopedProject`）。会话不在这里：在跑、等你的在会话条上，
/// 已结束的在"更早"（窄屏 Cue 页会话条底下那一格推入，宽屏会话条里展开）。
/// 窄屏那一排是侧栏的（`NarrowSidebarBar`：左边项目范围，右边额度）；宽屏页顶中间一块玻璃（`ProgressHeader`）：项目范围与额度环。
/// 两处的额度明细都是从额度长出、落在屏幕正中的浮窗（`popup`）。
/// 添加任务是待办头上的"+"、新会话是推进中头上的"+"（`LaneAdd`：竖版看板的行头、四列的列头），页顶不另放新会话。
/// 看板是流水看板（`TaskBoard`），待办 → 推进中 → 等你 → 已完成（今天）；选了项目以后卡上不画项目小图形、列头的数也只数这个项目。
/// 宽屏（iPad）与 iPhone 横屏同 Mac 四列并排（`BoardColumns`，主栏放不下四列最窄时整排横滑）；窄屏竖着拿是四行竖排、每行横划的竖版看板（`PhoneBoard`），
/// 四行一打开都在眼前，不另设落点。横屏的屏高减去顶栏只剩两百多点，四行连各自的最矮都叠不下；横过来的宽正好排四列。
/// 添加任务去待办、顶上浮出添加那一行（`NewTaskField`，落在范围里的项目或当前项目，可换），失焦且没写字时收回。
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

/// 宽屏进展页顶栏中间那一块玻璃：项目范围、额度环；点环长出居中的额度明细浮窗（`popup`，同窄屏侧栏的额度钮）。两样并成一块：说的都是"这一页看什么"。
/// 窄屏不用它：那一排是侧栏的（`NarrowSidebarBar`），项目范围与额度各是一颗圆钮。
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
