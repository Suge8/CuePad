#if os(macOS)
import CueStore
import CueBridge

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
        case BridgeError.unknownSession, BridgeError.unsupported,
             BridgeError.unknownModel, BridgeError.refused: true
        case BridgeError.rejected(let reason):
            ["empty", "not_ready", "unknown_command", "missing_argument", "no_prompt", "stale_prompt", "bad_answer", "no_auth",
             "nothing_to_retry", "unconfirmed_turn", "user_turn", "stale_turn", "unsupported_stop_turn", "upgrade_stop_turn"].contains(reason)
        // Agent 没起来、没连上就自己退出：话（含开工的开场白）还没交出。开工等不到连上（`notConnected`）例外，
        // 起得慢的可能已写下会话，`MacExecutor` 按未确认处理
        case PiHostError.notConnected, PiHostError.exited: true
        case AgentRuntimeError.notInstalled, AgentRuntimeError.openElsewhere: true
        default: false
        }
    }

}
#endif
