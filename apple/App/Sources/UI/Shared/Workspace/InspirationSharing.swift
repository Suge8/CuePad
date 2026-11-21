import Foundation
import Observation

@Observable
final class InspirationSharing {
    private enum Phase {
        case idle
        case preparing(InspirationShareRequest)
        case sharing(InspirationShareSession)
    }
    private var phase = Phase.idle

    var isBusy: Bool { if case .idle = phase { false } else { true } }
    var request: InspirationShareRequest? { if case .preparing(let request) = phase { request } else { nil } }
    var session: InspirationShareSession? { if case .sharing(let session) = phase { session } else { nil } }

    func prepare(source: String, originals: Bool) {
        phase = .preparing(InspirationShareRequest(source: source, originals: originals))
    }

    func prepared(_ payload: InspirationPayload, for request: InspirationShareRequest) {
        guard self.request?.id == request.id else { return }
        present(payload)
    }

    func present(_ payload: InspirationPayload) {
        phase = .sharing(InspirationShareSession(payload: payload) { [weak self] id in
            if self?.session?.id == id { self?.phase = .idle }
        })
    }

    func leave() {
        cancelPreparation()
        session?.cancelPresentation?()
    }

    func cancelPreparation() {
        if case .preparing = phase { phase = .idle }
    }
}

final class InspirationShareSession: Identifiable {
    let id = UUID()
    let payload: InspirationPayload
    var cancelPresentation: (() -> Void)?
    private var completion: ((UUID) -> Void)?

    init(payload: InspirationPayload, completion: @escaping (UUID) -> Void) {
        self.payload = payload
        self.completion = completion
    }

    func finish() {
        guard let completion else { return }
        self.completion = nil
        cancelPresentation = nil
        payload.files?.remove()
        completion(id)
    }
}
