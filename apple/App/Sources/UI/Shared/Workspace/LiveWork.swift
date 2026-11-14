import CueStore
import Foundation

extension Workspace {
    /// 各端"在做"读的唯一一份（菜单栏面板 `MenuBarLive` 列的就是它；几件推进中写在数字账里，这里不另按会话数）。只读已有的这几份，不另订阅。
    var liveWork: [SessionState] {
        let sessions = services.liveSessions
        #if os(macOS)
        let live = services.bridge.sessions.compactMap {
            SessionState.live($0, hostID: services.hostID, projectID: sendState.projects[$0.id], recap: sessions.recaps[$0.sessionID])
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
