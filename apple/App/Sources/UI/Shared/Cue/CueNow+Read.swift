import CueStore
import Foundation

/// Cue 此刻（`CueNow`）从库里怎么推：只从 Cue 的摘要来（`CueDigest`，推进中与等你只读 `CueStore.cueTally`），按此刻（`moment`）推 Cue 在不在、
/// 话在不在路上与刚做完的那几件，再配上库里没有的本机事实（`Local`）：还没和 iCloud 对过时不说没启用、写在等什么；
/// Mac 上它运行在别的 Mac 时静着那句写在哪台。Cue 那一行（`CueWatch.now`）、小组件快照与 iPhone 的实时活动（`AppServices.startSnapshots`）都经这里。
nonisolated extension CueNow {
    /// 本机知道、库里没有的（`AppServices.cueLocal`）：还没和 iCloud 对过时为什么等（`CueGate.waiting`，对过为 nil），这台 Mac 是哪台（手机为 nil）。
    struct Local: Equatable, Sendable {
        var waiting: String?
        var here: String?
    }

    init(_ digest: CueDigest, at moment: Speech.Moment, local: Local) {
        let presence = CuePresence.derive(digest, at: moment)
        let unconfirmed = digest.lastYou.map {
            Speech.trip(said: $0.said, delivered: $0.delivered, reachedServer: $0.reachedServer, host: digest.hostID, at: moment).unconfirmedReason != nil
        } ?? false
        var runtime = RuntimeTimeline(digest, at: moment)
        let items = Self.limited(Self.items(digest, works: runtime.items, at: moment.now)).enumerated().map { index, item in
            var item = item
            item.slot = index
            return item
        }
        let host = digest.hostName ?? MacAgents.unnamed
        self.init(
            name: digest.name, cue: Self.brain(presence, digest: digest, local: local, at: moment.now),
            tally: runtime.tally, advancing: runtime.advancing, subagents: runtime.subagents, items: items,
            first: digest.tally.waiting.first.map { Self.wait($0, name: digest.name) }, at: moment.now,
            elsewhere: digest.enabled && local.here != nil && digest.hostID != local.here ? String(localized: "在「\(host)」上运行") : nil,
            decay: runtime.decay(visible: items), unconfirmed: runtime.unconfirmed || presence.isUnconfirmed || unconfirmed || (!digest.hostOnline && digest.state?.state.isWorking == true), cueUntil: digest.hostUntil)
    }

    private static func brain(_ presence: CuePresence, digest: CueDigest, local: Local, at now: Date) -> Brain {
        // 库里没有 Cue 不等于哪台都没启用：还没和 iCloud 对过时写在等什么（同启用入口读的 `CueGate`）
        if presence == .disabled, let waiting = local.waiting { return .away(waiting, failed: false) }
        return switch presence {
        case .disabled, .asleep, .unconfirmed, .unreachable:
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
    private static func items(_ digest: CueDigest, works: [Item], at now: Date) -> [Item] {
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
        let done = digest.done.compactMap { task in
            task.completedAt.map { Item(id: "done/\(task.id.uuidString)", kind: .done, name: task.title, since: $0, subagents: 0) }
        }.filter { $0.isFresh(at: now) }
        return Item.Kind.allCases.flatMap { kind in (asks + replies + works + done).filter { $0.kind == kind } }
    }

    /// 截到 `itemLimit` 件，先后照旧；放不下时最后一格留给最近刚做完的那件（刚做完排在最后，照截就被截掉，头像与那一句就读不到它）。
    static func limited(_ items: [Item]) -> [Item] {
        guard items.count > itemLimit, let done = items.first(where: { $0.kind == .done }) else { return Array(items.prefix(itemLimit)) }
        return items.filter { $0.kind != .done }.prefix(itemLimit - 1) + [done]
    }

    private static func title(_ state: PiSessionState) -> String { state.title.isEmpty ? String(localized: "会话") : state.title }

    /// Cue 的提问：问句与下面那一句（同卡片与通知，`CueMessage.headline`、`CueAsking.why`），打开是 Cue 页，带选项的能"允许一次"（选第一项）；
    /// 会话在问：会话名与问题的第一行，打开是那个会话。
    static func wait(_ wait: CueTally.Wait, name: String) -> Wait {
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
