import CueStore
import SwiftUI

/// "在做"的那一列会话：Mac 侧栏的 Agent 区、Mac 菜单栏面板与手机、iPad Cue 页头的面板同一个。行是同一种（`PiSessionRow`，样式与点它做什么由调用处给），
/// 顺序同一个（`LiveWork.rows`，要你注意的在前）；两个以上需要 /reload 的会话合成一行（`PiReloadFold`），点开再列。
/// `limit` 给了就先列前几个（面板只是一瞥），多出的收成末尾一行"还有 N 个"，点开就地列全、末行换成"收起"——
/// 看全在原地，不用跳到全部会话页；总数在区头（`LiveWorkCount`）。
struct LiveSessionList<Row: View, Fold: View>: View {
    let sessions: [PiSessionState]
    var limit: Int?
    var spacing: CGFloat
    var style = PiSessionRow.Style.compact
    @ViewBuilder let row: (PiSessionState) -> Row
    @ViewBuilder let fold: (_ count: Int, _ expanded: Binding<Bool>) -> Fold
    @State private var reloadOpen = false
    @State private var showsAll = false

    var body: some View {
        let hidden = limit.map { max(sessions.count - $0, 0) } ?? 0
        let shown = hidden > 0 && !showsAll ? Array(sessions.prefix(limit ?? 0)) : sessions
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
            if hidden > 0 { LiveMoreFold(hidden: hidden, expanded: $showsAll, style: style) }
        }
        .animation(Motion.quick, value: showsAll)
    }
}

/// "在做"列末的那一行：收着时写"还有 N 个"，展开后写"收起"；箭头随之转向，与 /reload 那一行同一种灰字与箭头。
private struct LiveMoreFold: View {
    let hidden: Int
    @Binding var expanded: Bool
    let style: PiSessionRow.Style
    @Environment(\.palette) private var palette

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: style.dot + 2) {
                Text(expanded ? "收起" : "还有 \(hidden) 个").monospacedDigit()
                Image(systemName: "chevron.down").font(style.line.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(style.line.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.leading, style.dot * 1.8 + style.dot + 2)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起" : "还有 \(hidden) 个会话")
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }
}

/// 此刻在做的（各端"在做"读的唯一一份，`Workspace.liveWork`）：在线会话按要你注意的先后，与这些会话里在跑的子代理数。
/// 子代理只数会话自己报上来的（同步记录的 `PiSessionState.subagents`，四家同一个来源；报不出的那家就是 0，不估算），
/// 只数状态是在跑的（`PiSubagentPhase.running`）：在被审查的那个子代理自己是闲的，"同时在跑几个 Agent"不算它。
nonisolated struct LiveWork: Equatable {
    let rows: [PiSessionState]
    let subagents: Int

    init(rows: [PiSessionState]) {
        self.rows = rows
        subagents = rows.reduce(0) { $0 + $1.subagents.count { $0.phase == .known(.running) } }
    }

    var sessions: Int { rows.count }
}

/// 区头右边的计数："7 个会话 · 3 个子代理"（没有在跑的子代理只写会话数）：数字本身就是全部，报不出子代理的那几家不在里面，不另作说明。
struct LiveWorkCount: View {
    let work: LiveWork
    var font = Typography.meta
    @Environment(\.palette) private var palette

    var body: some View {
        Text(Dotted("\(work.sessions) 个会话", work.subagents > 0 ? "\(work.subagents) 个子代理" : nil))
            .font(font.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
            .contentTransition(.numericText())
            .animation(Motion.quick, value: work.sessions)
            .animation(Motion.quick, value: work.subagents)
            .accessibilityLabel(work.subagents > 0 ? "\(work.sessions) 个会话，\(work.subagents) 个子代理在跑" : "\(work.sessions) 个会话")
    }
}

extension Workspace {
    /// "在做"（`LiveSessionList` 列的与区头数的都是它）：同步记录里没结束的（别的 Mac 上的，`LiveSessions`），Mac 上再加本机桥上实时的
    /// （同一个会话只出现一次，本机实时优先），按要你注意的先后。只读已有的这几份，不另订阅。
    var liveWork: LiveWork {
        let sessions = services.liveSessions
        #if os(macOS)
        let live = services.pi.sessions.map {
            PiSessionState.live($0, hostID: services.hostID, projectID: sendState.projects[$0.id], recap: sessions.recaps[$0.sessionID])
        }
        #else
        let live: [PiSessionState] = []
        #endif
        return LiveWork(rows: PiSessionState.liveRows(
            live: live, recorded: sessions.live.map(\.listed), deliveries: sessions.deliveries, cueOnDuty: sessions.cueOnDuty, at: services.speech))
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
