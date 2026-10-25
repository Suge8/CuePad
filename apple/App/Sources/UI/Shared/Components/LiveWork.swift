import CueStore
import Foundation

/// 此刻在做的（各端"在做"读的唯一一份，`Workspace.liveWork`）：列出来的会话（在线的与正在唤醒的，按要你注意的先后），与同时在跑的 Agent——
/// 显示的状态在跑的会话（工作中、话在路上，`PiShown.isRunning`，与行上那颗状态标的靛青同一档；
/// 等你、出错、没能送达、歇着、新会话都不算），加上各会话里在跑的子代理（`PiSubagentState.isRunning`）。
/// 子代理只数会话自己报上来的（同步记录的 `PiSessionState.subagents`，四家同一个来源；报不出的那家就是 0，不估算）。
nonisolated struct LiveWork: Equatable {
    let rows: [PiSessionState]
    let running: Int
    let subagents: Int

    init(rows: [PiSessionState], running: (PiSessionState) -> Bool) {
        self.rows = rows
        self.running = rows.count(where: running)
        subagents = rows.reduce(0) { $0 + $1.subagents.count(where: \.isRunning) }
    }
}

extension Workspace {
    /// "在做"（菜单栏面板 `MenuBarLive` 列的与区头数的都是它）：同步记录里没结束的（别的 Mac 上的，`LiveSessions`）与正在唤醒的，Mac 上再加本机桥上实时的
    /// （同一个会话只出现一次，本机实时优先），按要你注意的先后。只读已有的这几份，不另订阅。
    var liveWork: LiveWork {
        let sessions = services.liveSessions
        #if os(macOS)
        let live = services.pi.sessions.compactMap {
            PiSessionState.live($0, hostID: services.hostID, projectID: sendState.projects[$0.id], recap: sessions.recaps[$0.sessionID])
        }
        #else
        let live: [PiSessionState] = []
        #endif
        let rows = PiSessionState.liveRows(
            live: live, recorded: sessions.current.map(\.listed), deliveries: sessions.deliveries, cue: sessions.cue, at: services.speech)
        return LiveWork(rows: rows) { shown($0, delivery: sessions.deliveries[$0.sessionID]).isRunning }
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
