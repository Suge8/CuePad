#if os(macOS)
import CueBridge
import CueStore
import SwiftUI

extension SessionState {
    /// 状态记录按节流写，会落后几秒，界面读这个：桥上的报告落在同步记录（`stored`）上，摘要、为哪件任务开这些桥上没有的照记录。
    /// 正自己换上新扩展的（`upgrading`）桥上读不到状态，为 nil：界面照同步记录里最后一次读到的样子。
    static func live(_ session: CueBridge.Session, over stored: SessionState?, hostID: String, projectID: UUID?) -> SessionState? {
        guard !session.upgrading else { return nil }
        let report = session.snapshot(title: session.displayName, projectID: projectID)
        return SessionState(report, over: stored, hostID: hostID, bootID: SystemBoot.id, at: session.stateSince).connected()
    }
}

extension SessionDigest {
    static func read(sessionID: String, from store: isolated CueStore) throws -> SessionDigest {
        try read(SessionState.recordID(sessionID: sessionID), sessionID: sessionID, from: store)
    }

    func live(_ session: CueBridge.Session?, hostID: String, project: Project?) -> SessionDigest {
        guard let session,
              let state = SessionState.live(
                session, over: self.session, hostID: hostID, projectID: project?.id ?? self.session?.projectID)
        else { return self }
        var digest = self
        digest.session = state
        digest.catalog = AgentCatalog(host: hostID, models: session.availableModels, commands: session.commands, at: session.stateSince)
        if let project { digest.project = project }
        return digest
    }
}

extension View {
    /// 不给 `press` 是侧栏里的一行，给了是卡片或圆钮的按压。
    func sessionLink(_ sessionID: String, press: Press? = nil) -> some View { modifier(SessionLink(sessionID: sessionID, press: press)) }
}

private struct SessionLink: ViewModifier {
    let sessionID: String
    let press: Press?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        let opened = workspace.shownSessions.contains { $0.sessionID == sessionID }
        let button = Button {
            workspace.openSession(SessionState.recordID(sessionID: sessionID), sessionID: sessionID,
                                  in: NSEvent.modifierFlags.contains(.command) ? .beside : .main)
        } label: {
            content.contentShape(.rect)
        }
        Group {
            if let press { button.buttonStyle(PressStyle(press)) } else { button.buttonStyle(RowStyle(selected: opened)) }
        }
        .accessibilityAddTraits(opened ? .isSelected : [])
        .accessibilityHint("打开会话")
        .draggable(DraggedSession(sessionID: sessionID))
    }
}

extension Workspace {
    /// 本机在线的会话换上桥上的实时状态（同步记录按节流写，会落后几秒）；其余原样。
    func withLiveState(_ session: SessionState) -> SessionState {
        guard let live = services.bridge.session(sessionID: session.sessionID) else { return session }
        return .live(live, over: session, hostID: services.hostID, projectID: sendState.projects[live.id] ?? session.projectID) ?? session
    }

    func withLiveState(_ item: SessionListItem) -> SessionListItem {
        var item = item
        item.state = withLiveState(item.state)
        return item
    }
}
#endif
