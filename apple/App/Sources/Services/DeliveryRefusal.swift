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
        case PiHostError.notConnected: true
        default: false
        }
    }

}
#endif
