import CueStore
import Foundation

/// 会话条唯一的数据口径：从 `cueTally` 同一次读取里取 `works`（即 `CueBoard.active`）的所有未结束会话，加上等你的会话，按 sessionID 去重。
/// 等你同看板：会话拍板在前、待回复在后，各自等得最久的在前；Cue 自己的提问不列。因此名牌的「拍板」= 会话拍板 + Cue 提问，
/// 会话条只数会话拍板；「推进中」数会话，不是名牌与看板的工作项数。一项工作有多个会话、一个会话参与多项工作时不能拿两处数字相减。
/// 从 works 而不是 advancing 展开：一个会话等你会让整项任务被 held 占着，其余并行会话仍要留在推进中。歇着也是 active，不按图形的 rank 偷删。
nonisolated struct SessionRailData: Equatable, Sendable {
    struct Waiting: Equatable, Sendable {
        let agent: SessionListItem
        let deciding: Bool
    }

    var waiting: [Waiting]
    var advancing: [SessionListItem]

    static func read(from store: isolated CueStore) throws -> Self {
        let tally = try store.cueTally()
        let asking = tally.waiting.compactMap { wait in
            if case .session(let session, _) = wait { session } else { nil }
        }.sorted { ($0.stateSince, $0.sessionID) < ($1.stateSince, $1.sessionID) }
        let waiting = asking + tally.replies.map(\.session)
        var seen = Set(waiting.map(\.sessionID))
        let advancing = tally.works.flatMap(\.sessions)
            .sorted { ($0.stateSince, $0.sessionID) > ($1.stateSince, $1.sessionID) }
            .filter { seen.insert($0.sessionID).inserted }
        let items = try store.sessionItems(sessionIDs: waiting.map(\.sessionID) + advancing.map(\.sessionID))
        let decisions = Set(asking.map(\.sessionID))
        return Self(
            waiting: waiting.map { Waiting(agent: items[$0.sessionID]!, deciding: decisions.contains($0.sessionID)) },
            advancing: advancing.map { items[$0.sessionID]! })
    }
}

struct SessionRailRows {
    struct Item: Identifiable {
        let session: SessionState
        let name: String
        let pulse: BoardPulse
        let waiting: SessionShown.Status?
        var id: String { session.sessionID }
    }

    let waiting: [Item]
    let advancing: [Item]

    init(_ data: SessionRailData, pulse: (SessionListItem) -> BoardPulse) {
        func item(_ value: SessionListItem, waiting: SessionShown.Status?) -> Item {
            let pulse = pulse(value)
            let session = pulse.session ?? value.state
            return Item(session: session, name: value.task?.title.nonEmpty ?? session.title, pulse: pulse, waiting: waiting)
        }
        waiting = data.waiting.map { item($0.agent, waiting: $0.deciding ? .asking : .awaitsReply) }
        advancing = data.advancing.map { item($0, waiting: nil) }.enumerated().sorted {
            let left = $0.element.pulse, right = $1.element.pulse
            return (left.tier, left.shown?.rank ?? 0, $0.offset) < (right.tier, right.shown?.rank ?? 0, $1.offset)
        }.map(\.element)
    }
}
