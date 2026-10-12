#if os(macOS)
import CueStore
import SwiftUI

/// 工具栏右边的"⋯"：当前页的操作。会话页是会话的（`SessionMenuItems`）；项目页（含未分类）是选择灵感、新建任务，
/// 以及项目的操作（`ProjectActions`，未分类没有项目）；其余页没有可放的，隐去。
/// 这个菜单项一直在工具栏里（没有内容时透明、点不到），只换里面的内容：它在工具栏的一组里时增删会让整组重建，一次进出会话页约占动作后主线程 CPU 的三分之一到一半。
struct PageMenuSlot: View {
    @Environment(Workspace.self) private var workspace

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
        case .session: workspace.shownSessionHeader.flatMap { $0.showsMenu && $0.hasActions ? .session($0) : nil }
        case .project(let id): .project(id)
        case .unfiled: .project(nil)
        default: nil
        }
    }

    var body: some View {
        let content = content
        Menu("更多", systemImage: "ellipsis") {
            switch content {
            case .session(let state): SessionMenuItems(state: state)
            case .project(let id): ProjectMenuItems(projectID: id)
            case nil: EmptyView()
            }
        }
        .menuIndicator(.hidden)
        .help(content?.help ?? "")
        .opacity(content == nil ? 0 : 1)
        .disabled(content == nil)
        .accessibilityHidden(content == nil)
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
