import SwiftUI

/// 尺寸只由窗口与两栏内容推出；自动收窄不改用户的开合选择。
struct WideMetrics {
    static let board: CGFloat = 756
    static let session: CGFloat = 420
    static let cue: CGFloat = 400
    let rail: CGFloat
    let main: CGFloat
    let side: CGFloat

    /// 会话条自动收窄的临界窗口宽：宽版会话条加主栏下限（看板或会话）、右栏下限（Cue 或会话）。
    static func threshold(_ workspace: Workspace) -> CGFloat {
        let minimum = workspace.mainRoute == .progress && workspace.progressPane == .board ? board : session
        return SessionRail.Form.wide.width + minimum + (workspace.sideSession == nil ? cue : session)
    }

    init(width: CGFloat, workspace: Workspace) {
        let right = workspace.sideSession == nil ? Self.cue : Self.session
        let wide = workspace.sidebarOpen && width >= Self.threshold(workspace)
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

extension EnvironmentValues {
    /// 宽屏主栏放得下看板四列的最窄宽（`WideMetrics.board`）：放不下时 iPad 的进展页换成竖版看板（`ProgressScreen`），不把四列压窄。
    @Entry var boardFits = true
}

struct WideRail: View {
    let width: CGFloat
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

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
            SessionRail(data: services.liveSessions.rail, form: width == SessionRail.Form.wide.width ? .wide : .narrow,
                        marked: Set(workspace.shownSessions.compactMap(\.sessionID)), pulse: workspace.pulse) { session, opening in
                workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .leading ? .main : .side)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width)
        .background(palette.sidebar)
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
