import CueStore
import Foundation
import Observation

@Observable
final class Launching {
    private struct Pressed: Equatable {
        let id: UUID
        let target: SendingTarget
    }

    private var pressed: [Pressed] = []

    func contains(_ target: SendingTarget) -> Bool { pressed.contains { $0.target == target } }

    func begin(_ id: UUID, to target: SendingTarget) { pressed.append(Pressed(id: id, target: target)) }

    func failed(_ id: UUID) { pressed.removeAll { $0.id == id } }

    func observed(_ target: SendingTarget, seen: (UUID) -> Bool) {
        guard let last = pressed.lastIndex(where: { $0.target == target && seen($0.id) }) else { return }
        pressed = pressed.enumerated().filter { $0.offset > last || $0.element.target != target }.map(\.element)
    }
}

extension SendingTarget {
    init(_ session: SessionState) { self.init(host: session.hostID, target: session.target) }
}
