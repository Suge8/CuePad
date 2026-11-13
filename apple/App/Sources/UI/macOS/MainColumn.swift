#if os(macOS)
import CueStore
import SwiftUI

struct MainColumn: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset

    private var session: Bool { if case .session = workspace.mainRoute, workspace.overlay == nil { true } else { false } }

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                PageStack()
                Group {
                    EditorLayer()
                    LibraryFileLayer()
                }
                .safeAreaPadding(.top, Chrome.band)
                .zIndex(1)
            }
            .overlay(alignment: .bottom) { CaptureSlot() }
            if !session { head }
        }
        .environment(\.topBand, Chrome.band)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// 进展页那一排是看板的列头：栏头只占右端那几颗钮，不盖住列头（空处拖窗口由看板自己接）。
    @ViewBuilder private var head: some View {
        if workspace.mainRoute == .progress, workspace.overlay == nil {
            MainHead().padding(inset).frame(maxWidth: .infinity, alignment: .trailing).frame(height: Chrome.band)
        } else {
            MainHead().padding(inset).frame(height: Chrome.band).windowDragArea()
        }
    }
}

struct BesideColumn: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group {
            if let id = workspace.besideSession?.sessionID { SessionPage(sessionID: id, column: .beside).id(id) }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct MainHead: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        HStack(spacing: 0) {
            if workspace.overlay != nil {
                CloseButton()
                OverlayTitle()
            } else {
                page
            }
            Spacer(minLength: Spacing.item)
            // 看板那一排是列头，不给提醒常驻一格（列头少让一截）；要关注时才露
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            if workspace.overlay == nil, workspace.mainRoute == .shelf { NewProjectSlot() }
            PageMenuSlot()
        }
    }

    @ViewBuilder private var page: some View {
        switch workspace.mainRoute {
        case .project: WideProjectHeading()
        case .shelf: WideHeading(title: String(localized: "项目"))
        case .archive: WideHeading(title: String(localized: "归档"))
        case .trash: WideHeading(title: String(localized: "回收站"))
        case .library: LibraryPanesSlot()
        default: EmptyView()
        }
    }
}

private struct NewProjectSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("新建项目")
            .padding(.leading, Spacing.item)
    }
}

extension EnvironmentValues {
    @Entry var topBand: CGFloat = 0
}
#endif
