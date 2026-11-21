import CueStore
import Observation

@Observable
final class Launching {
    private var keys: Set<SendingTarget> = []

    func contains(_ session: SessionState) -> Bool { keys.contains(SendingTarget(host: session.hostID, target: session.target)) }
    func begin(_ session: SessionState) { keys.insert(SendingTarget(host: session.hostID, target: session.target)) }
    func settle(_ session: SessionState) { keys.remove(SendingTarget(host: session.hostID, target: session.target)) }
    func settle(host: String, target: SendTarget) { keys.remove(SendingTarget(host: host, target: target)) }
}
