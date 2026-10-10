#if os(macOS)
import CueStore
import SwiftUI

/// 菜单栏面板：Pi 状态（点会话在主窗口里打开它的整页：面板只是一瞥，读与回复在主窗口，与手机一致）+ 随手记（与主窗口底部同一个 `CaptureComposer`，一直展开）。
/// 各块各是一片玻璃、中间留空，面板自己没有底（输入框自带玻璃，外面再包一层就是玻璃套玻璃）。资料库读到之前没有输入框；读不出来时说明原因并给"重试"。
struct MenuBarPad: View {
    var openSession: (String) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var capture = CaptureState()

    private static let sessionLimit = 4
    private static let blockRadius: CGFloat = 22
    private static let blockPadding: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sessions = PiSessionState.inListOrder(services.pi.sessions.map {
                PiSessionState.live(
                    $0, hostID: services.hostID, projectID: workspace.sessionProjects[$0.id], recap: services.liveSessions.recaps[$0.sessionID])
            }).prefix(Self.sessionLimit)
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(sessions, id: \.sessionID) { session in
                        PiSessionRow(
                            session: session, project: workspace.catalog?.project(session.projectID),
                            delivery: services.liveSessions.deliveries[session.sessionID], undelivered: services.liveSessions.undelivered[session.sessionID] ?? 0).equatable()
                            .contentShape(.rect)
                            .onTapGesture { openSession(session.sessionID) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { openSession(session.sessionID) }
                    }
                }
                .modifier(Block())
            }
            if workspace.isLibraryReady {
                CaptureComposer(state: $capture, defaultProject: services.settings.currentProject, pinnedOpen: true)
            } else if let failure = workspace.catalogFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Label("读不出资料库", systemImage: "exclamationmark.triangle").font(Typography.secondary.weight(.medium))
                    Text(failure).font(Typography.meta).foregroundStyle(.secondary).lineLimit(4)
                    Button("重试") { workspace.retryCatalog() }
                }
                .foregroundStyle(palette.ink)
                .modifier(Block())
            }
        }
        .frame(width: 360)
        .modifier(SessionProjectsTracker(workspace: workspace))
    }

    private struct Block: ViewModifier {
        func body(content: Content) -> some View {
            content
                .padding(MenuBarPad.blockPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(in: .rect(cornerRadius: MenuBarPad.blockRadius))
        }
    }
}
#endif
