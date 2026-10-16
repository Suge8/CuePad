import CueStore
import SwiftUI

/// "在做"的那一列会话：Mac 侧栏的 Agent 区、Mac 菜单栏面板与手机 Cue 页头的面板同一个。行是同一种（`PiSessionRow`，样式与点它做什么由调用处给），
/// 顺序同一个（`Workspace.liveSessionRows`，要你注意的在前）；两个以上需要 /reload 的会话合成一行（`PiReloadFold`），点开再列。
/// `limit` 给了就只列前几个（面板只是一瞥，全部在 Agent 整页里）。
struct LiveSessionList<Row: View, Fold: View>: View {
    let sessions: [PiSessionState]
    var limit: Int?
    var spacing: CGFloat
    @ViewBuilder let row: (PiSessionState) -> Row
    @ViewBuilder let fold: (_ count: Int, _ expanded: Binding<Bool>) -> Fold
    @State private var reloadOpen = false

    var body: some View {
        let shown = limit.map { Array(sessions.prefix($0)) } ?? sessions
        // 在线的按会话 id 区分：状态变化时那一行不被重建
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(PiNowRow.rows(shown, state: { $0 })) { nowRow in
                switch nowRow {
                case .session(let session): row(session)
                case .reload(let sessions):
                    fold(sessions.count, $reloadOpen)
                    if reloadOpen { ForEach(sessions) { row($0) } }
                }
            }
        }
    }
}

extension Workspace {
    /// "在做"的会话（`LiveSessionList` 列的就是它）：同步记录里没结束的（别的 Mac 上的，`LiveSessions`），Mac 上再加本机桥上实时的
    /// （同一个会话只出现一次，本机实时优先），按要你注意的先后。只读已有的这几份，不另订阅。
    var liveSessionRows: [PiSessionState] {
        let sessions = services.liveSessions
        #if os(macOS)
        let live = services.pi.sessions.map {
            PiSessionState.live($0, hostID: services.hostID, projectID: sendState.projects[$0.id], recap: sessions.recaps[$0.sessionID])
        }
        #else
        let live: [PiSessionState] = []
        #endif
        return PiSessionState.liveRows(
            live: live, recorded: sessions.live.map(\.listed), deliveries: sessions.deliveries, cueOnDuty: sessions.cueOnDuty, at: services.speech)
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
    /// "现在"的会话行：本机在线的（桥上实时，`live`）与同步记录里没结束的（别的 Mac 上的）一起按要你注意的先后；
    /// 同一个会话只出现一次（本机实时优先）。已结束的不列，历史在 Agent 整页里。`recorded` 是会话列表查询的一页。
    static func liveRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], cueOnDuty: Bool = false,
        at moment: Speech.Moment
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) && $0.state != .known(.ended) }
        return inListOrder(live + others, deliveries: deliveries, cueOnDuty: cueOnDuty, at: moment)
    }
}
