import CueStore
import Foundation

/// Cue 此刻（`CueNow`）从库里怎么推：只从 Cue 的摘要来（`CueDigest`，推进中与等你只读 `CueStore.cueTally`），按此刻（`moment`）推 Cue 在不在、
/// 话在不在路上、表情与刚做完的那几颗，再配上库里没有的本机事实（`Local`）：还没和 iCloud 对过时不说没启用、写在等什么；
/// Mac 上它运行在别的 Mac 时静着那句写在哪台。Cue 那一行（`CueWatch.now`）、小组件快照与 iPhone 的实时活动（`AppServices.startSnapshots`）都经这里。
nonisolated extension CueNow {
    /// 本机知道、库里没有的（`AppServices.cueLocal`）：还没和 iCloud 对过时为什么等（`CueGate.waiting`，对过为 nil），这台 Mac 是哪台（手机为 nil）。
    struct Local: Equatable, Sendable {
        var waiting: String?
        var here: String?
    }

    init(_ digest: CueDigest, at moment: Speech.Moment, local: Local) {
        let presence = CuePresence.derive(digest, at: moment)
        let beads = Self.beads(digest, at: moment.now)
        let host = digest.hostName ?? MacAgents.unnamed
        self.init(
            name: digest.name, mood: digest.mood(at: moment),
            restingMood: CueMood.of(.idle, waiting: digest.waiting, justDone: digest.lastSaidDone),
            cue: Self.brain(presence, digest: digest, local: local, at: moment.now),
            beads: Array(beads.prefix(Self.beadLimit)), hidden: max(beads.count - Self.beadLimit, 0), counts: Counts(beads), advancing: digest.advancing,
            first: digest.tally.waiting.first.map { Self.wait($0, name: digest.name) }, at: moment.now,
            elsewhere: digest.enabled && local.here != nil && digest.hostID != local.here ? "在「\(host)」上运行" : nil)
    }

    private static func brain(_ presence: CuePresence, digest: CueDigest, local: Local, at now: Date) -> Brain {
        // 库里没有 Cue 不等于哪台都没启用：还没和 iCloud 对过时写在等什么（同启用入口读的 `CueGate`）
        if presence == .disabled, let waiting = local.waiting { return .away(waiting, failed: false) }
        return switch presence {
        case .disabled, .asleep, .unreachable:
            .away(presence.line(host: digest.hostName ?? MacAgents.unnamed, ranBefore: digest.hostID != nil) ?? digest.name, failed: presence.isUnreachable)
        case .idle: .idle
        case .sending: .hearing
        case .working:
            // 这一轮从醒的那一刻算（Cue 自己醒的轮记着），回你话的那一轮从交给它的那一刻算，都没有时从它写下此刻的状态算
            .working(
                woke: digest.woke?.text, doing: presence.isUsingTool ? presence.progress : nil,
                since: digest.woke?.at ?? digest.lastYou?.delivered ?? digest.state?.modifiedAt ?? now)
        }
    }

    /// 等你的每一件、待回复的每个会话、推进中的每一件、刚做完的每一件，按这个先后（同一种里照摘要的先后）。
    /// 会话都待回复的事不另算一颗歇着的：它的会话已经各是一颗待回复。
    private static func beads(_ digest: CueDigest, at now: Date) -> [Bead] {
        let asks = digest.tally.waiting.map { wait in
            switch wait {
            case .message(let message, _):
                Bead(id: wait.id, kind: .asks, name: message.asking?.action ?? message.headline ?? "\(digest.name) 在等你", since: message.createdAt,
                     subagents: 0, sessions: [])
            case .session(let state, _):
                Bead(id: wait.id, kind: .asks, name: title(state), since: state.stateSince, subagents: 0, sessions: [state.sessionID])
            }
        }
        let replies = digest.tally.replies.map { Bead(id: "reply/\($0.sessionID)", kind: .reply, name: title($0), since: $0.stateSince, subagents: 0, sessions: [$0.sessionID]) }
        let replied = Set(digest.tally.replies.map(\.sessionID))
        let works = digest.tally.advancing.map(bead).filter { $0.kind != .resting || $0.sessions.isEmpty || !Set($0.sessions).isSubset(of: replied) }
        let done = digest.done.compactMap { task in
            task.completedAt.map { Bead(id: "done/\(task.id.uuidString)", kind: .done, name: task.title, since: $0, subagents: 0, sessions: []) }
        }.filter { $0.isFresh(at: now) }
        return Bead.Kind.allCases.flatMap { kind in (asks + replies + works + done).filter { $0.kind == kind } }
    }

    /// 推进中的一件：有会话在跑（在想、用工具、压缩，或正在开、话正送进去）是在跑，从最早在跑的那一轮起算；
    /// 否则有会话在等子代理是等交回，数它们在跑的子代理；再否则歇着。
    private static func bead(_ work: CueWork) -> Bead {
        let sessions: [PiSessionState], name: String, pending: Bool, settledSince: Date
        switch work {
        case .task(let item):
            sessions = item.leaves.compactMap(\.session).filter { $0.state != .known(.ended) }
            name = item.task.title
            pending = item.leaves.contains { $0.launching || $0.sending }
            settledSince = item.leaves.map(\.since).min() ?? item.task.modifiedAt
        case .session(let state):
            sessions = [state]
            name = title(state)
            pending = false
            settledSince = state.stateSince
        }
        let ids = sessions.map(\.sessionID)
        let running = sessions.filter { $0.state.isWorking && $0.state != .known(.delegating) }
        if pending || !running.isEmpty {
            let since = running.map { $0.busySince ?? $0.stateSince }.min() ?? settledSince
            return Bead(id: work.id, kind: .running, name: name, since: since, subagents: 0, sessions: ids)
        }
        let delegating = sessions.filter { $0.state == .known(.delegating) }
        if !delegating.isEmpty {
            return Bead(
                id: work.id, kind: .delegating, name: name, since: delegating.map(\.stateSince).min() ?? settledSince,
                subagents: delegating.reduce(0) { $0 + $1.subagents.count(where: \.isRunning) }, sessions: ids)
        }
        return Bead(id: work.id, kind: .resting, name: name, since: sessions.map(\.stateSince).max() ?? settledSince, subagents: 0, sessions: ids)
    }

    private static func title(_ state: PiSessionState) -> String { state.title.isEmpty ? "会话" : state.title }

    /// Cue 的提问：要做的动作（`CueAsking.action`）与它请你允许哪一类事，打开是 Cue 页，带选项的能"允许一次"（选第一项）；
    /// 会话在问：会话名与问题的第一行，打开是那个会话。
    private static func wait(_ wait: CueTally.Wait, name: String) -> Wait {
        switch wait {
        case .message(let message, _):
            let asking = message.asking
            return Wait(
                title: asking?.action ?? message.headline ?? "\(name) 在等你",
                detail: asking.map { $0.request(by: name) },
                open: DeepLink.cue.url,
                allow: message.choices?.first.map { Allow(message: message.id, choice: $0) })
        case .session(let state, _):
            let question = state.question?.text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return Wait(
                title: title(state),
                detail: question.flatMap { $0.isEmpty ? nil : $0 } ?? "在等你回答",
                open: DeepLink.session(state.id).url,
                allow: nil)
        }
    }
}
