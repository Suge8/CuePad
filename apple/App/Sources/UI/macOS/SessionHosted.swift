#if os(macOS)
import CueBridge
import CueStore
import SwiftUI

extension SessionState {
    static func hosted(_ session: CueBridge.Session, over stored: SessionState?, hostID: String, projectID: UUID?) -> SessionState? {
        guard !session.upgrading else { return nil }
        let report = session.snapshot(title: session.displayName, projectID: projectID)
        return SessionState(report, over: stored, hostID: hostID, bootID: SystemBoot.id, at: session.stateSince).connected()
    }
}

extension SessionDigest {
    static func read(sessionID: String, from store: isolated CueStore) throws -> SessionDigest {
        try read(SessionState.recordID(sessionID: sessionID), sessionID: sessionID, from: store)
    }

    func hosted(_ session: CueBridge.Session?, hostID: String, project: Project?) -> SessionDigest {
        guard let session,
              let state = SessionState.hosted(
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
                                  in: NSEvent.modifierFlags.contains(.command) ? .aside : .main)
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
    func withLiveState(_ session: SessionState) -> SessionState {
        guard let live = services.bridge.session(sessionID: session.sessionID) else { return session }
        return .hosted(live, over: session, hostID: services.hostID, projectID: sendState.projects[live.id] ?? session.projectID) ?? session
    }

    func withLiveState(_ item: SessionListItem) -> SessionListItem {
        var item = item
        item.state = withLiveState(item.state)
        return item
    }
}
#endif
