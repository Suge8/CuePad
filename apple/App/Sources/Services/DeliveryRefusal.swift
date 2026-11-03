#if os(macOS)
import CueStore
import CuePi

nonisolated enum DeliveryRefusal {
    static func afterStarting(_ outcome: DeliveryOutcome) -> DeliveryOutcome {
        switch outcome {
        case .failed(let reason): .unconfirmed(reason)
        default: outcome
        }
    }

    static func definitelyNotHanded(_ error: any Error) -> Bool {
        switch error {
        case is SendError: true
        case CueStoreError.cannotSpeakNow, CueStoreError.terminalOnly, CueStoreError.sessionUnconfirmed, CueStoreError.turnSourceUnconfirmed: true
        case PiBridgeError.unknownSession, PiBridgeError.unsupported,
             PiBridgeError.unknownModel: true
        case PiBridgeError.rejected(let reason):
            ["empty", "unknown_command", "missing_argument", "no_prompt", "stale_prompt", "bad_answer", "no_auth",
             "nothing_to_retry", "unconfirmed_turn", "user_turn"].contains(reason)
        // Agent 没起来、没连上就自己退出：话（含开工的开场白）还没交出。开工等不到连上（`notConnected`）例外，
        // 起得慢的可能已写下会话，`MacExecutor` 按未确认处理
        case PiHostError.notConnected, PiHostError.exited: true
        case AgentRuntimeError.notInstalled, AgentRuntimeError.openElsewhere: true
        default: false
        }
    }

}
#endif
