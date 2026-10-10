#if os(macOS)
import CueStore
import SwiftUI

/// 菜单栏面板：Pi 状态（点会话在主窗口里打开它的整页：面板只是一瞥，读与回复在主窗口，与手机一致）+ 随手记（与主窗口底部同一个 `CaptureComposer`，一直展开）。
/// 资料库读到之前没有稿纸；读不出来时说明原因并给"重试"。
struct MenuBarPad: View {
    var openSession: (String) -> Void = { _ in }
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static let sessionLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let sessions = PiSessionState.inListOrder(services.pi.sessions.map {
                PiSessionState.live(
                    $0, hostID: services.hostID, projectID: workspace.sessionProjects[$0.id], recap: workspace.sessionRecaps[$0.sessionID])
            }).prefix(Self.sessionLimit)
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(sessions, id: \.sessionID) { session in
                        PiSessionRow(
                            session: session, project: workspace.catalog?.project(session.projectID),
                            delivery: workspace.sessionDeliveries[session.sessionID], undelivered: workspace.sessionUndelivered[session.sessionID] ?? 0).equatable()
                            .contentShape(.rect)
                            .onTapGesture { openSession(session.sessionID) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { openSession(session.sessionID) }
                    }
                }
                .padding([.horizontal, .top], 6)
            }
            if workspace.isLibraryReady {
                capture
            } else if let failure = workspace.catalogFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Label("读不出资料库", systemImage: "exclamationmark.triangle").font(Typography.secondary.weight(.medium))
                    Text(failure).font(Typography.meta).foregroundStyle(.secondary).lineLimit(4)
                    Button("重试") { workspace.retryCatalog() }
                }
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
        }
        // 内边距 8：里面稿纸的圆角 14 + 8 = 外框 22，同心
        .padding(8)
        .frame(width: 360)
        .glass(in: .rect(cornerRadius: 22))
        .modifier(SessionProjectsTracker(workspace: workspace))
    }

    private var capture: some View {
        CaptureComposer(defaultProject: services.settings.currentProject, pinnedOpen: true, minHeight: 72)
            .overlay(alignment: .bottomLeading) {
                if let notice = workspace.notice {
                    Text(notice.text).font(Typography.meta)
                        .foregroundStyle(notice.isError ? palette.failure : palette.ink3)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: workspace.notice)
    }
}
#endif
