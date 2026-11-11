#if os(macOS)
import CueStore
import CueBridge
import Foundation

@MainActor
struct MacDeliveryPreparation {
    let bridge: Bridge

    func current(_ request: DeliveryRequest) -> DeliveryAdmission {
        guard let mode = request.mode.known, DeliveryMode.requiresReadySession.contains(mode),
              request.target.kind == .known(.piSession), let sessionID = request.target.ref else { return .ready(.resumable) }
        if let live = bridge.session(sessionID: sessionID) {
            return live.upgrading ? .waiting(waiting(for: sessionID)) : .ready(.existingOnly)
        }
        return request.status == .known(.preparing) ? .waiting(waiting(for: sessionID)) : .ready(.resumable)
    }

    func waiting(for sessionID: String) -> DeliveryPreparation {
        DeliveryPreparation(reason: DeliveryPreparation.upgrading) { [bridge] in
            let changes = await bridge.changes()
            if await Self.isReady(sessionID, in: bridge) { return }
            for await _ in changes {
                try Task.checkCancellation()
                if await Self.isReady(sessionID, in: bridge) { return }
            }
            throw CancellationError()
        }
    }

    private static func isReady(_ sessionID: String, in bridge: Bridge) -> Bool {
        bridge.session(sessionID: sessionID).map { !$0.upgrading } ?? false
    }
}

#endif
