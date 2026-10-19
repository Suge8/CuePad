#if os(macOS)
import CueStore
import SwiftUI

/// 工具栏右上的"⋯"：当前页的操作。会话页是会话的（`SessionMenuItems`）；项目页（含未分类）是选择灵感、新建任务，
/// 以及项目的操作（`ProjectActions`，未分类没有项目）；其余页没有可放的，钮置灰。
/// 它是单独的工具栏项、不共用系统的玻璃底（`sharedBackgroundVisibility(.hidden)`），圆钮的玻璃自己画，与"收起"同一种做法。
/// 钮在每一页都在、只随页面置灰：工具栏项的尺寸一变整条工具栏重排（一次进出会话页约占动作后主线程 CPU 的三分之一到一半）。
/// 会话页的钮跟着页面就在，菜单里的会话项等页面交来的值、并晚于标题两帧（`showsMenu`）。
struct PageMenuSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private enum Content: Equatable {
        /// 会话页；页面还没交来值时是 nil。
        case session(SessionHeader.State?)
        /// 项目页；未分类是 nil。
        case project(UUID?)
        case cue
        case none

        var help: String {
            switch self {
            case .session: "完成或绑定任务、重命名、跳到终端、结束会话"
            case .project: "选择灵感、新建任务、项目操作"
            case .cue: "记得什么"
            case .none: ""
            }
        }
    }

    private var content: Content {
        switch workspace.page {
        case .session: .session(workspace.shownSessionHeader)
        case .project(let id): .project(id)
        case .unfiled: .project(nil)
        case .cue: .cue
        default: .none
        }
    }

    var body: some View {
        let content = content
        Menu {
            switch content {
            case .session(let state?): if state.showsMenu { SessionMenuItems(state: state) }
            case .project(let id): ProjectMenuItems(projectID: id)
            case .cue:
                Button("\(workspace.cue.name) 记得什么", icon: .memory) { workspace.cue.showsMemory = true }
                // 运行情况给开发者看：只在 Cue 于这台 Mac 值班时有（经过只在值班的管理器里）
                if workspace.services.cue.keeper != nil {
                    Toggle("运行情况", icon: .session, isOn: Bindable(workspace.cue).showsRun)
                }
                Button("Cue 设置…", icon: .settings) { SettingsPane.open(.cue) }
            case .session(nil), .none: EmptyView()
            }
        } label: {
            Image(.more).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.ink)
                .frame(width: Spacing.toolbarControl, height: Spacing.toolbarControl)
                .contentShape(.circle)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(content == .none)
        .glass(in: .circle, interactive: true, ink: .clear)
        .help(content.help)
        .accessibilityLabel("更多")
    }
}

/// 项目页"⋯"里的几项：进入批量选择（`CardPresses`，一条都还没选，点卡再选）、新建任务（打开任务面板，光标在添加任务那一行，落在本项目）、项目的操作。
private struct ProjectMenuItems: View {
    let projectID: UUID?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let ready = workspace.isLibraryReady
        Button("选择灵感", icon: CardMenu.Item.select.icon) { workspace.presses.beginSelecting() }
            .disabled(!ready || (workspace.catalog?.cardCounts[projectID] ?? 0) == 0)
        Button("新建任务", icon: .task) { workspace.showsTasks = true }
            .disabled(!ready)
        if let project = projectID.flatMap({ workspace.catalog?.project($0) }) {
            Divider()
            ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
        }
    }
}
#endif
