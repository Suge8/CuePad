import SwiftUI

/// 宽屏主区的栏头（Mac 主窗口与 iPad 宽窗同一个）：左边写这一页是什么，右边是这一页的操作。会话页的栏头在会话页里（`WideSessionTitle`）。
/// iPad 上页的操作是页自己那一排的右端（`HeaderHost.column`），与这里同一排；Mac 的页没有那一排，操作在这里的"⋯"（`PageMenuSlot`）。
struct WideColumnHead: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            #if os(macOS)
            if workspace.overlay != nil {
                CloseButton()
                OverlayTitle()
            } else if workspace.mainRoute == .progress {
                PageMenuSlot(leads: true)
            } else {
                title
            }
            Spacer(minLength: Spacing.item)
            // 看板那一排是列头，不给提醒常驻一格（列头少让一截）；要关注时才露
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            if workspace.overlay == nil, workspace.mainRoute == .shelf {
                NewProjectButton()
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .circular))
                    .padding(.leading, Spacing.item)
            }
            if workspace.overlay != nil || workspace.mainRoute != .progress { PageMenuSlot() }
            #else
            title
            Spacer(minLength: Spacing.item)
            #endif
        }
    }

    @ViewBuilder private var title: some View {
        switch workspace.mainRoute {
        case .project: WideProjectHeading()
        case .shelf: WideHeading(title: String(localized: "项目"))
        case .archive: WideHeading(title: String(localized: "归档"))
        case .trash: WideHeading(title: String(localized: "回收站"))
        case .library: LibraryPanesSlot()
        case .settings: WideHeading(title: String(localized: "设置"))
        case .conflicts: WideHeading(title: String(localized: "两个版本"))
        case .earlier: WideHeading(title: String(localized: "历史"))
        default: EmptyView()
        }
    }
}

struct NewProjectButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
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
