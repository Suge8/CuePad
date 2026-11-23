import CueStore
import SwiftUI

/// 页那一块的栏头：胶囊（`PaneTitle`）在左上角，这一页直接可点的钮挨着它。进展没有胶囊，栏头是看板自己的列头。
struct WideColumnHead: View {
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let page = workspace.pageRoute
        HStack(spacing: Spacing.item) {
            if page == .progress { ProjectScopeSlot() } else if let page { title(page) }
            Spacer(minLength: Spacing.item)
            #if os(macOS)
            if page != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            #endif
        }
    }

    private var close: (() -> Void)? { workspace.isSplit ? { workspace.closeColumn(column) } : nil }

    private var shelf: PaneTitle<EmptyView, EmptyView>.Crumb { .init(title: String(localized: "项目")) { workspace.select(.shelf) } }

    @ViewBuilder private func title(_ page: Route) -> some View {
        switch page {
        case .project(let id):
            if let project = workspace.catalog?.project(id) {
                PaneTitle(crumb: .init(title: shelf.title, action: shelf.action), title: project.shownName, handle: .page(page), close: close, menu: {
                    ProjectActions(project: project, folders: false)
                })
                tools { ProjectHeadTools(project: project) }
            }
        case .shelf:
            PaneTitle(title: String(localized: "项目"), handle: .page(page), close: close)
            tools {
                NewProjectButton()
                Button("归档", icon: .archive) { workspace.show(.archive) }.help("归档")
                Button("回收站", icon: .trash) { workspace.show(.trash) }.help("回收站")
            }
        case .archive: PaneTitle(crumb: shelf, title: String(localized: "归档"), handle: .page(page), close: close)
        case .trash:
            PaneTitle(crumb: shelf, title: String(localized: "回收站"), handle: .page(page), close: close)
            tools { EmptyTrashButton() }
        case .library:
            PaneTitle(title: String(localized: "技能与规则"), handle: .page(page), close: close)
            LibraryPanesSlot()
        case .settings: PaneTitle(title: String(localized: "设置"), handle: .page(page), close: close)
        case .conflicts: PaneTitle(title: String(localized: "两个版本"), handle: .page(page), close: close)
        default: EmptyView()
        }
    }

    private func tools(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: 0) { buttons() }
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .buttonStyle(ControlButtonStyle(kind: .icon))
    }
}

struct NewProjectButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新建项目", icon: .add) { workspace.projectForm = .init() }
            .help("新建项目")
    }
}

private struct LibraryPanesSlot: View {
    var body: some View {
        LibraryPanes()
            .frame(height: PaneMetrics.square)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule)
            .fixedSize()
    }
}
