#if os(macOS)
import SwiftUI

/// 任务页（侧栏"任务"、⌘⇧T）：流水看板（`TaskBoard`）四列并排——待办 → 推进中 → 等你 → 做完（今天），每列各自滚动（`BoardColumn`）。
/// 顶上不写页名（侧栏的选中格已经说了在哪一页），左边是项目范围（`ProjectScopeMenu`，同会话页那一份；选了项目以后列头的数也只数这个项目）、
/// 右边"新任务"（待办顶上浮出添加那一行，落在范围里的项目或当前项目）。
struct TaskBoardPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?
    @State private var adding = false

    var body: some View {
        let scope = workspace.scopedProject
        VStack(alignment: .leading, spacing: 18) {
            topRow
            BoardColumns(board: (board ?? .empty).only(scope), adding: $adding, newTaskProject: scope ?? workspace.currentProject)
        }
        .padding(.horizontal, Spacing.page - 8).padding(.top, Spacing.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.desk)
        .animation(Motion.quick, value: adding)
        .onChange(of: workspace.projectScope) { adding = false }
        .observingBoard(into: $board, store: services.store, onError: workspace.fail)
    }

    private var topRow: some View {
        HStack(spacing: 16) {
            ProjectScopeMenu()
            Spacer(minLength: 0)
            Button { adding.toggle() } label: {
                Label("新任务", icon: .add)
                    .font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
                    .padding(.horizontal, 14).frame(height: Spacing.toolbarControl)
                    .glass(in: .capsule, interactive: true)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .help("在待办里添加任务")
        }
        .padding(.horizontal, 8)
    }
}
#endif
