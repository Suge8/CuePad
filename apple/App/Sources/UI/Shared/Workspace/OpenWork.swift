import CueStore
import Foundation

extension Workspace {
    var openWork: [SessionState] {
        let sessions = services.sessionFeed
        #if os(macOS)
        let live = services.bridge.sessions.compactMap {
            SessionState.hosted($0, over: sessions.recorded[$0.sessionID], hostID: services.hostID, projectID: sendState.projects[$0.id])
        }
        #else
        let live: [SessionState] = []
        #endif
        let shown = Set(live.map(\.sessionID))
        let recorded = sessions.current.map(\.listed).filter { !shown.contains($0.sessionID) }
        return SessionState.inListOrder(live + recorded, state: \.self, deliveries: sessions.deliveries, cue: sessions.cue, at: services.speech)
    }
}

nonisolated extension SessionListItem {
    var listed: SessionState {
        var session = state
        if project == nil { session.projectID = nil }
        return session
    }
}
