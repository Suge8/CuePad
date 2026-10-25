import CueStore
import Foundation

extension Workspace {
    /// "在做"（各端"在做"读的唯一一份，菜单栏面板 `MenuBarLive` 列的就是它；几件在推进按件数写在数字账里，这里不另按会话数）：同步记录里没结束的（别的 Mac 上的，`LiveSessions`）与正在唤醒的，Mac 上再加本机桥上实时的
    /// （同一个会话只出现一次，本机实时优先），按要你注意的先后。只读已有的这几份，不另订阅。
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
    /// 列表里的会话；所属项目已删的不再带项目（按文件夹归组、写文件夹名）。
    var listed: PiSessionState {
        var session = state
        if project == nil { session.projectID = nil }
        return session
    }
}

extension PiSessionState {
    /// "现在"的会话行：本机在线的（桥上实时，`live`）与同步记录里要列的（`recorded`：别的 Mac 上没结束的、正在唤醒的）一起按要你注意的先后；
    /// 同一个会话只出现一次（本机实时优先）。其余已结束的不列，历史在 进展页的会话段里。
    static func liveRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], cue: CueDuty? = nil,
        at moment: Speech.Moment
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) }
        return inListOrder(live + others, state: \.self, deliveries: deliveries, cue: cue, at: moment)
    }
}
