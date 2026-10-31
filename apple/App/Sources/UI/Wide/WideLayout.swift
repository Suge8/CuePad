import SwiftUI

/// 尺寸只由窗口与两栏内容推出；自动收窄不改用户的开合选择。
struct WideMetrics {
    static let board: CGFloat = 756
    static let session: CGFloat = 420
    static let cue: CGFloat = 400
    let rail: CGFloat
    let main: CGFloat
    let side: CGFloat

    init(width: CGFloat, workspace: Workspace) {
        let minimum = workspace.mainRoute == .progress && workspace.progressPane == .board ? Self.board : Self.session
        let right = workspace.sideSession == nil ? Self.cue : Self.session
        let wide = workspace.sidebarOpen && width >= SessionRail.Form.wide.width + minimum + right
        rail = wide ? SessionRail.Form.wide.width : SessionRail.Form.narrow.width
        let available = max(0, width - rail)
        if case .session = workspace.mainRoute, workspace.sideSession != nil {
            main = available / 2
        } else {
            main = max(available / 2, available - right)
        }
        side = available - main
    }
}

struct WideRail: View {
    let width: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: SessionRailData?

    var body: some View {
        VStack(spacing: 8) {
            Button { workspace.show(.cue) } label: {
                HStack {
                    Image(.cue).font(.title)
                    if width == SessionRail.Form.wide.width {
                        Text(workspace.cue.name).font(.headline)
                        Spacer()
                    }
                }
                .padding(12)
            }
            .buttonStyle(.row)
            .accessibilityLabel(workspace.cue.name)
            .relaySpot(cue: .entry)
            if let data {
                SessionRail(data: data, form: width == SessionRail.Form.wide.width ? .wide : .narrow,
                            marked: Set(workspace.shownSessions.compactMap(\.sessionID)), pulse: workspace.pulse) { session, opening in
                    workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .leading ? .main : .side)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(palette.sidebar)
        .observing(services.store, into: $data, onError: workspace.fail) { try SessionRailData.read(from: $0) }
    }
}

struct WidePlaces: View {
    @Environment(Workspace.self) private var workspace

    private var browsing: Bool {
        guard case .wide(let navigation) = workspace.navigation else { return false }
        if case .browse = navigation.main { return true }
        return false
    }

    var body: some View {
        PaneSegment<NavigationPane?>(items: [
            .init(value: .projects, title: "项目", icon: .folder),
            .init(value: .progress, title: "进展", icon: .task),
        ], selection: browsing ? workspace.navigationPane : nil) { pane in
            if let pane { workspace.selectPane(pane) }
        }
        .frame(height: PaneMetrics.square)
        .padding(PaneMetrics.inset)
        .glass(in: .capsule)
        .fixedSize()
    }
}
