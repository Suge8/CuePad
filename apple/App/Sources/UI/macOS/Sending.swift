#if os(macOS)
import CueBridge
import CueStore
import CueText
import SwiftUI

extension Workspace {
    @discardableResult
    func handOff(_ leaf: Card) -> Task<Void, Never>? {
        handOff(leaf.id, fresh: false)
    }

    @discardableResult
    func send(_ stored: String, to target: AgentTarget, card: UUID? = nil) -> Task<Void, Never> {
        let (listener, handed) = sendState.destination(to: target, card: card)
        return speak(stored, to: listener, saying: handed)
    }
}

extension Workspace {
    func followSessionPlacement() async {
        for await _ in Observations({ self.sessionPlacement }) {
            do { try await sendState.refreshSessionProjects() } catch { fail(error) }
        }
    }

    private struct SessionPlacement: Equatable {
        var sessions: [String]
        var directories: [UUID: String]?
    }

    private var sessionPlacement: SessionPlacement {
        SessionPlacement(sessions: services.bridge.slots.map { "\($0.id) \($0.cwd.path)" }, directories: catalog?.directories)
    }
}
#endif
