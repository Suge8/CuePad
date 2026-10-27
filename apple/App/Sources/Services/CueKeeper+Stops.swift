#if os(macOS)
import CueAgent
import CueStore
import Foundation

extension CueKeeper {
    /// 会话停下叫醒的一轮正常做完时，兜底每个会话都有去处：此刻仍停在报给 Cue 的那次停下（`Turn.stops`）、没留给他回、没结束，
    /// 这一轮也没对它（或它绑的任务）说话、留给他回、收回、做完、就它问他（`CueActivity.settlesStop`）的，替 Cue 留给他回（`CueStore.leaveUnattended`，同 task leave）。
    /// 留的这一步记成一次 leave 调用进这一轮的经过，Cue 页照它显示"留给你"。出错的一轮不兜底：重试时 Cue 再看。
    func leaveUnattended() async {
        guard let turn, turn.round.failure == nil, !turn.stops.isEmpty else { return }
        let given = Set(turn.round.calls.filter { !$0.failed && CueActivity.settlesStop(tool: $0.name, arguments: $0.arguments) }
            .flatMap { [$0.named.task, $0.named.session] }.compactMap(\.self))
        var record: UUID?
        for stop in turn.stops {
            do {
                guard let (session, row) = try await store.leaveUnattended(stop, given: given) else { continue }
                record = row
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "leave", "session": session.sessionID]), as: UTF8.self)
                let id = "unattended-\(session.sessionID)"
                await began(id, "task", arguments)
                await ended(id, result: "这一轮没给它去处，CuePad 已替你把它留给他回。", failed: false)
            } catch {
                Self.log.error("没给去处的停下没能留给他回：\(error.localizedDescription, privacy: .public)")
            }
        }
        if let record { await setup.upload([record]) }
    }
}
#endif
