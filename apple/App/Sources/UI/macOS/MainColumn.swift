#if os(macOS)
import CueStore
import SwiftUI

struct MainColumn: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under

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
                .padding(.trailing, under)
                .zIndex(1)
            }
            .overlay(alignment: .bottom) { CaptureSlot().padding(.trailing, under) }
            if !session { head.padding(.trailing, under) }
        }
        .environment(\.topBand, Chrome.band)
        .ignoresSafeArea(.container, edges: .top)
    }

    /// 进展页那一排是看板的列头：栏头只占两端那几颗钮（左端项目范围、右端要关注时的同步提醒），不盖住列头（空处拖窗口由看板自己接）。
    @ViewBuilder private var head: some View {
        if workspace.mainRoute == .progress, workspace.overlay == nil {
            MainHead().padding(inset).frame(height: Chrome.band)
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
            } else if workspace.mainRoute == .progress {
                PageMenuSlot(leads: true)
            } else {
                page
            }
            Spacer(minLength: Spacing.item)
            // 看板那一排是列头，不给提醒常驻一格（列头少让一截）；要关注时才露
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            if workspace.overlay == nil, workspace.mainRoute == .shelf { NewProjectSlot() }
            if workspace.overlay != nil || workspace.mainRoute != .progress { PageMenuSlot() }
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
    /// 主区右端压在 Cue 浮板下面多宽（`MainWindow`）。别的页整页让出它（`PageStack`）；看板只按让出后的宽分列，放不下横滑时列滑到浮板下面（`TaskBoardPage`）。
    @Entry var underCue: CGFloat = 0
}
#endif
