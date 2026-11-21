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

    static func definitelyNotHanded(_ mode: Open<DeliveryMode>, _ error: any Error) -> Bool {
        switch error {
        case is SendError: true
        case let error as BridgeError: error.definitelyNotHanded
        case PiHostError.notConnected: mode != .known(.start)
        case PiHostError.exited: true
        case AgentRuntimeError.notInstalled, AgentRuntimeError.openElsewhere: true
        default: false
        }
    }

}
#endif
