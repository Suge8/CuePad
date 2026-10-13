#if os(macOS)
import CueStore
import SwiftUI

/// 工具栏右上的"⋯"：当前页的操作。会话页是会话的（`SessionMenuItems`）；项目页（含未分类）是选择灵感、新建任务，
/// 以及项目的操作（`ProjectActions`，未分类没有项目）；其余页没有可放的，不出现、不占位。
/// 它是单独的工具栏项、不共用系统的玻璃底（`sharedBackgroundVisibility(.hidden)`），圆钮的玻璃自己画，与"收起"同一种做法：
/// 项一直在，只有里面的钮出没（增删工具栏项会重建整条工具栏，一次进出会话页约占动作后主线程 CPU 的三分之一到一半）。
/// 会话页的钮与标题同一圈出现（项的尺寸只变一次，换会话时不变），菜单里的会话项晚两帧（`showsMenu`）。
struct PageMenuSlot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private enum Content {
        case session(SessionHeader.State)
        /// 项目页；未分类是 nil。
        case project(UUID?)

        var help: String {
            switch self {
            case .session: "重命名、跳到终端、结束会话"
            case .project: "选择灵感、新建任务、项目操作"
            }
        }
    }

    private var content: Content? {
        switch workspace.page {
        case .session: workspace.shownSessionHeader.flatMap { $0.hasActions ? .session($0) : nil }
        case .project(let id): .project(id)
        case .unfiled: .project(nil)
        default: nil
        }
    }

    var body: some View {
        if let content {
            Menu {
                switch content {
                case .session(let state): if state.showsMenu { SessionMenuItems(state: state) }
                case .project(let id): ProjectMenuItems(projectID: id)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).foregroundStyle(palette.ink)
                    .frame(width: Spacing.toolbarControl, height: Spacing.toolbarControl)
                    .contentShape(.circle)
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .glass(in: .circle, interactive: true)
            .help(content.help)
            .accessibilityLabel("更多")
        }
    }
}

/// 项目页"⋯"里的几项：进入批量选择（`CardPresses`，一条都还没选，点卡再选）、新建任务（打开任务面板，光标在添加任务那一行，落在本项目）、项目的操作。
private struct ProjectMenuItems: View {
    let projectID: UUID?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let ready = workspace.isLibraryReady
        Button("选择灵感", systemImage: CardMenu.Item.select.symbol) { workspace.presses.beginSelecting() }
            .disabled(!ready || (workspace.catalog?.cardCounts[projectID] ?? 0) == 0)
        Button("新建任务", systemImage: "checklist") { workspace.showsTasks = true }
            .disabled(!ready)
        if let project = projectID.flatMap({ workspace.catalog?.project($0) }) {
            Divider()
            ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
        }
    }
}
#endif
