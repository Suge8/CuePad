#if os(macOS)
import CueStore
import SwiftUI

/// 工具栏右上的"⋯"：当前页的操作，只放页上已有的动作；没有可放的页（归档）钮停用、同系统停用的控件那样变淡（与可用时一个样子，点了没反应像是坏了）。
/// 其余页（归档）没有可放的，钮停用、同系统停用的控件那样变淡（与可用时一个样子，点了没反应像是坏了）。
/// 菜单项不按页面数据置灰：菜单拿不到页面读的库，抄一份过来就是第二个事实源；没有可归档、可清空的时候点了什么也不发生。
/// 它是单独的工具栏项、不共用系统的玻璃底（`sharedBackgroundVisibility(.hidden)`），圆钮的玻璃自己画，与"收起"同一种做法。
/// 钮在每一页都在、只随页面置灰：工具栏项的尺寸一变整条工具栏重排（一次进出会话页约占动作后主线程 CPU 的三分之一到一半）。
/// 会话页的钮跟着页面就在，菜单里的会话项等页面交来的值、并晚于标题两帧（`showsMenu`）。
struct PageMenuSlot: View {
    @Environment(Workspace.self) private var workspace

    private enum Content: Equatable {
        /// 会话页；页面还没交来值时是 nil。
        case session(SessionHeader.State?)
        case project(UUID)
        case cue
        case tasks
        case agent
        case trash
        case none

        var help: String {
            switch self {
            case .session: "完成或绑定任务、重命名、跳到终端、结束会话"
            case .project: "选择灵感、看这个项目的会话、项目操作"
            case .cue: "记得什么"
            case .tasks: "新任务、归档做完的"
            case .agent: "新会话、接入 Agent"
            case .trash: "清空回收站"
            case .none: "这一页没有更多操作"
            }
        }
    }

    private var content: Content {
        switch workspace.page {
        case .session: .session(workspace.shownSessionHeader)
        case .project(let id): .project(id)
        case .cue: .cue
        case .tasks: .tasks
        case .agent: .agent
        case .trash: .trash
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
                Button("\(workspace.cue.name) 的设置…", icon: .settings) { SettingsPane.open(.cue) }
            case .tasks:
                Button("新任务", icon: .add) { workspace.addsTask = true }
                Button("全部归档做完的", icon: .archive) { workspace.attempt { try await workspace.archiveCompletedTasks() } }
            case .agent:
                Button("新会话", icon: .add) { workspace.showsNewSession = true }
                Button("接入 Agent…", icon: .extensionNote) { workspace.showsSetup = true }
            case .trash:
                Button("清空回收站…", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
            case .session(nil), .none: EmptyView()
            }
        } label: {
            Image(.more)
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .fixedSize()
        .disabled(content == .none)
        .help(content.help)
        .accessibilityLabel("更多")
    }
}

/// 项目页"⋯"里的几项：进入批量选择（`CardPresses`，一条都还没选，点卡再选）、看这个项目的会话（任务页与会话页共用的项目范围设成它，再去会话页）、项目的操作。
/// 添加任务就在页上的任务区里。
private struct ProjectMenuItems: View {
    let projectID: UUID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let ready = workspace.isLibraryReady
        Button("选择灵感", icon: CardMenu.Item.select.icon) { workspace.presses.beginSelecting() }
            .disabled(!ready || (workspace.catalog?.cardCounts[projectID] ?? 0) == 0)
        Button("看这个项目的会话", icon: .session) {
            workspace.projectScope = projectID
            workspace.show(.agent)
        }
        if let project = workspace.catalog?.project(projectID) {
            Divider()
            ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
        }
    }
}
#endif
