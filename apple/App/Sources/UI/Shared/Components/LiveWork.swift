import CueStore
import Foundation

extension Workspace {
    /// 各端"在做"读的唯一一份（菜单栏面板 `MenuBarLive` 列的就是它；几件推进中写在数字账里，这里不另按会话数）。只读已有的这几份，不另订阅。
    var liveWork: [PiSessionState] {
        let sessions = services.liveSessions
        #if os(macOS)
        let live = services.pi.sessions.compactMap {
            PiSessionState.live($0, hostID: services.hostID, projectID: sendState.projects[$0.id], recap: sessions.recaps[$0.sessionID])
        }
        #else
        let live: [PiSessionState] = []
        #endif
        return PiSessionState.liveRows(
            live: live, recorded: sessions.current.map(\.listed), deliveries: sessions.deliveries, cue: sessions.cue, at: services.speech)
    }
}

nonisolated extension PiSessionListItem {
    var listed: PiSessionState {
        var session = state
        if project == nil { session.projectID = nil }
        return session
    }
}

extension PiSessionState {
    static func liveRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], cue: CueDuty? = nil,
        at moment: Speech.Moment
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) }
        return inListOrder(live + others, state: \.self, deliveries: deliveries, cue: cue, at: moment)
    }
}
