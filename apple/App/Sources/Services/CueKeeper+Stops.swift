#if os(macOS)
import CueAgent
import CueStore
import Foundation

extension CueKeeper {
    func leaveUnattended() async {
        guard let turn, turn.round.failure == nil, !turn.stops.isEmpty else { return }
        let given = Set(turn.round.calls.filter { !$0.failed && CueActivity.settlesStop(tool: $0.name, arguments: $0.arguments) }
            .flatMap { [$0.named.task, $0.named.session] }.compactMap(\.self))
        for stop in turn.stops {
            do {
                guard let session = try await store.leaveUnattended(stop, given: given) else { continue }
                let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "leave", "session": session.sessionID]), as: UTF8.self)
                let id = "unattended-\(session.sessionID)"
                await began(id, "task", arguments)
                await ended(id, result: "这一轮没给它去处，CuePad 已替你把它留给他回。", failed: false)
            } catch {
                Self.log.error("没给去处的停下没能留给他回：\(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
#endif
