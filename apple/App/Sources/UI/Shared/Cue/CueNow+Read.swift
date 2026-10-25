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
        let items = Self.items(digest, at: moment.now)
        let host = digest.hostName ?? MacAgents.unnamed
        let tally = Tally(
            asks: items.count { $0.kind == .asks }, reply: items.count { $0.kind == .reply },
            running: items.count { $0.kind == .running }, delegating: items.count { $0.kind == .delegating })
        self.init(
            // 头像此刻的表情（不算你正在写）与歇下来时的那一个：有没有等你只看 `needsYou` 那一个数
            name: digest.name, mood: CueMood.of(presence, waiting: tally.needsYou, justDone: digest.lastSaidDone),
            restingMood: CueMood.of(.idle, waiting: tally.needsYou, justDone: digest.lastSaidDone),
            cue: Self.brain(presence, digest: digest, local: local, at: moment.now),
            tally: tally,
            advancing: digest.advancing, items: Array(items.prefix(Self.itemLimit)),
            first: digest.tally.waiting.first.map { Self.wait($0, name: digest.name) }, at: moment.now,
            elsewhere: digest.enabled && local.here != nil && digest.hostID != local.here ? String(localized: "在「\(host)」上运行") : nil)
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

    /// 拍板的每一件、待回复的每个会话、推进中的每一件、刚做完的每一件，按这个先后（同一种里照摘要的先后）。
    private static func items(_ digest: CueDigest, at now: Date) -> [Item] {
        let asks = digest.tally.waiting.map { wait in
            switch wait {
            case .message(let message, _):
                Item(id: wait.id, kind: .asks, name: message.asking?.action ?? message.headline ?? String(localized: "\(digest.name) 等你拍板"), since: message.createdAt, subagents: 0)
            case .session(let state, _):
                Item(id: wait.id, kind: .asks, name: title(state), since: state.stateSince, subagents: 0)
            }
        }
        let replies = digest.tally.replies.map { reply in
            Item(id: reply.id, kind: .reply, name: title(reply.session), since: reply.session.stateSince, subagents: 0)
        }
        let works = digest.tally.advancing.map(item)
        let done = digest.done.compactMap { task in
            task.completedAt.map { Item(id: "done/\(task.id.uuidString)", kind: .done, name: task.title, since: $0, subagents: 0) }
        }.filter { $0.isFresh(at: now) }
        return Item.Kind.allCases.flatMap { kind in (asks + replies + works + done).filter { $0.kind == kind } }
    }

    /// 推进中的一件：有会话在跑（在想、用工具、压缩，或正在开、话正送进去）是在跑，从最早在跑的那一轮起算；
    /// 否则有会话在等子代理是等交回，数它们在跑的子代理；再否则歇着。
    private static func item(_ work: CueWork) -> Item {
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
        let running = sessions.filter { $0.state.isWorking && $0.state != .known(.delegating) }
        if pending || !running.isEmpty {
            let since = running.map { $0.busySince ?? $0.stateSince }.min() ?? settledSince
            return Item(id: work.id, kind: .running, name: name, since: since, subagents: 0)
        }
        let delegating = sessions.filter { $0.state == .known(.delegating) }
        if !delegating.isEmpty {
            return Item(
                id: work.id, kind: .delegating, name: name, since: delegating.map(\.stateSince).min() ?? settledSince,
                subagents: delegating.reduce(0) { $0 + $1.subagents.count(where: \.isRunning) })
        }
        return Item(id: work.id, kind: .resting, name: name, since: sessions.map(\.stateSince).max() ?? settledSince, subagents: 0)
    }

    private static func title(_ state: PiSessionState) -> String { state.title.isEmpty ? String(localized: "会话") : state.title }

    /// Cue 的提问：问句与下面那一句（同卡片与通知，`CueMessage.headline`、`CueAsking.why`），打开是 Cue 页，带选项的能"允许一次"（选第一项）；
    /// 会话在问：会话名与问题的第一行，打开是那个会话。
    private static func wait(_ wait: CueTally.Wait, name: String) -> Wait {
        switch wait {
        case .message(let message, _):
            return Wait(
                title: message.headline ?? String(localized: "\(name) 等你拍板"),
                detail: message.asking?.why,
                open: DeepLink.cue.url,
                allow: message.choices?.first.map { Allow(message: message.id, choice: $0) })
        case .session(let state, _):
            let question = state.question?.text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            return Wait(
                title: title(state),
                detail: question.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "在等你回答"),
                open: DeepLink.session(state.id).url,
                allow: nil)
        }
    }
}
