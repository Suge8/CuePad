import CueStore
import SwiftUI

/// "在做"的那一列会话：Mac 菜单栏面板与手机、iPad Cue 页头的面板同一个。行是同一种（`PiSessionRow`，样式与点它做什么由调用处给），
/// 顺序同一个（`LiveWork.rows`，要你注意的在前）。
/// `limit` 给了就先列前几个（面板只是一瞥），多出的收成末尾一行"还有 N 个"，点开就地列全、末行换成"收起"——
/// 看全在原地，不用跳到全部会话页；区头写有几个在跑（`LiveWorkCount`）。
struct LiveSessionList<Row: View>: View {
    let sessions: [PiSessionState]
    var limit: Int?
    var spacing: CGFloat
    var style = PiSessionRow.Style.compact
    @ViewBuilder let row: (PiSessionState) -> Row
    @State private var showsAll = false

    var body: some View {
        let hidden = limit.map { max(sessions.count - $0, 0) } ?? 0
        let shown = hidden > 0 && !showsAll ? Array(sessions.prefix(limit ?? 0)) : sessions
        // 在线的按会话 id 区分：状态变化时那一行不被重建
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(shown) { row($0) }
            if hidden > 0 { LiveMoreFold(hidden: hidden, expanded: $showsAll, style: style) }
        }
        .animation(Motion.quick, value: showsAll)
    }
}

/// "在做"列末的那一行：收着时写"还有 N 个"，展开后写"收起"；箭头随之转向。
private struct LiveMoreFold: View {
    let hidden: Int
    @Binding var expanded: Bool
    let style: PiSessionRow.Style
    @Environment(\.palette) private var palette

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: style.dot + 2) {
                Text(expanded ? "收起" : "还有 \(hidden) 个").monospacedDigit()
                Image(.expand).font(style.line.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(style.line.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.leading, style.dot * 1.8 + style.dot + 2)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(expanded ? "收起" : "还有 \(hidden) 个会话")
        .accessibilityExpanded(expanded)
    }
}

/// 此刻在做的（各端"在做"读的唯一一份，`Workspace.liveWork`）：列出来的会话（在线的与正在唤醒的，按要你注意的先后），与同时在跑的 Agent——
/// 显示的状态在跑的会话（工作中、话在路上，`PiShown.isRunning`，与行上那颗状态标的靛青同一档；
/// 等你、出错、没能送达、歇着、新会话都不算），加上各会话里在跑的子代理（`PiSubagentState.isRunning`）。
/// 子代理只数会话自己报上来的（同步记录的 `PiSessionState.subagents`，四家同一个来源；报不出的那家就是 0，不估算）。
nonisolated struct LiveWork: Equatable {
    let rows: [PiSessionState]
    /// 此刻在跑的会话数。
    let running: Int
    /// 在跑的子代理数。
    let subagents: Int

    init(rows: [PiSessionState], running: (PiSessionState) -> Bool) {
        self.rows = rows
        self.running = rows.count(where: running)
        subagents = rows.reduce(0) { $0 + $1.subagents.count(where: \.isRunning) }
    }
}

/// 区头右边的计数，只写在跑的："2 个在跑 · 2 个子代理"；只有子代理在跑时写"2 个子代理在跑"，都停着写"都停着"。
/// 数字本身就是全部：报不出子代理的那几家不在里面，不另作说明；列了几行不在这里重复（多出的那一行写"还有 N 个"）。
struct LiveWorkCount: View {
    let work: LiveWork
    var font = Typography.meta
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(font.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
            .contentTransition(.numericText())
            .animation(Motion.quick, value: work.running)
            .animation(Motion.quick, value: work.subagents)
    }

    private var text: Dotted {
        switch (work.running, work.subagents) {
        case (0, 0): "都停着"
        case (0, let agents): Dotted("\(agents) 个子代理在跑")
        case (let sessions, 0): Dotted("\(sessions) 个在跑")
        case (let sessions, let agents): Dotted("\(sessions) 个在跑", "\(agents) 个子代理")
        }
    }
}

extension Workspace {
    /// "在做"（`LiveSessionList` 列的与区头数的都是它）：同步记录里没结束的（别的 Mac 上的，`LiveSessions`）与正在唤醒的，Mac 上再加本机桥上实时的
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
    /// 同一个会话只出现一次（本机实时优先）。其余已结束的不列，历史在 Agent 整页里。
    static func liveRows(
        live: [PiSessionState], recorded: [PiSessionState], deliveries: [String: DeliveryRequest] = [:], cue: CueDuty? = nil,
        at moment: Speech.Moment
    ) -> [PiSessionState] {
        let shown = Set(live.map(\.sessionID))
        let others = recorded.filter { !shown.contains($0.sessionID) }
        return inListOrder(live + others, state: \.self, deliveries: deliveries, cue: cue, at: moment)
    }
}
