#if os(macOS)
import CueStore
import CuePi
import Foundation

@MainActor
struct MacDeliveryPreparation {
    let pi: PiBridge

    func current(_ request: DeliveryRequest) -> DeliveryAdmission {
        guard let mode = request.mode.known, DeliveryMode.requiresReadySession.contains(mode),
              request.target.kind == .known(.piSession), let sessionID = request.target.ref else { return .ready(.resumable) }
        if let live = pi.session(sessionID: sessionID) {
            return live.upgrading ? .waiting(waiting(for: sessionID)) : .ready(.existingOnly)
        }
        return request.status == .known(.preparing) ? .waiting(waiting(for: sessionID)) : .ready(.resumable)
    }

    func waiting(for sessionID: String) -> DeliveryPreparation {
        DeliveryPreparation(reason: DeliveryPreparation.upgrading) { [pi] in
            let changes = await pi.changes()
            if await Self.isReady(sessionID, in: pi) { return }
            for await _ in changes {
                try Task.checkCancellation()
                if await Self.isReady(sessionID, in: pi) { return }
            }
            throw CancellationError()
        }
    }

    private static func isReady(_ sessionID: String, in pi: PiBridge) -> Bool {
        pi.session(sessionID: sessionID).map { !$0.upgrading } ?? false
    }
}

#endif
