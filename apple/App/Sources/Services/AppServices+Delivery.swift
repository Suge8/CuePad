import CueStore
import Foundation

extension AppServices {
    func withdraw(_ said: Said) async throws {
        guard said.trip(at: speech).unconfirmedReason == nil else { throw SendError.alreadyHanded }
        switch said {
        case .request(let request) where request.status == .known(.failed):
            guard try await store.withdrawFailedDelivery(request.id) else { throw SendError.alreadyHanded }
        case .request(let request):
            if try await !store.withdrawDelivery(request.id, locallyOn: speech.localHost) {
                guard request.status == .known(.preparing) else { throw SendError.alreadyHanded }
                try await withdrawRemotely(request.id, on: request.hostID)
                try await store.deleteDelivery(request.id)
            }
        case .cue(let message, _):
            guard try await store.withdrawCueMessage(message.id) else { throw SendError.alreadyHeard }
        }
    }

    private func withdrawRemotely(_ id: UUID, on host: String) async throws {
        var withdrawal: DeliveryRequest?
        let result: DeliveryRequest
        do {
            result = try await awaitOutcome(onTimeout: SendError.withdrawalPending) {
                try await request(on: host) {
                    guard let written = try await store.requestDeliveryWithdrawal(id) else { throw SendError.alreadyHanded }
                    withdrawal = written
                    return written
                }
            }
        } catch SendError.withdrawalPending {
            if let withdrawal, try await store.withdrawDelivery(withdrawal.id) { throw SendError.alreadyHanded }
            throw SendError.withdrawalPending
        }
        guard result.status == .known(.succeeded) else { throw SendError.alreadyHanded }
    }

    func startDeliveryCleanup() {
        follow { [store, syncing, timing] in
            while !Task.isCancelled {
                let started = timing.now()
                let pulled = (try? await syncing.engine?.syncNow()).map { $0 != .incomplete } ?? false
                var wake = started.addingTimeInterval(pulled ? 86_400 : 3_600)
                if pulled {
                    do {
                        if let next = try await store.deleteExpiredDeliveries(pulledAt: started) { wake = min(wake, next) }
                    } catch {
                        Self.log.error("到期的投送请求没能清掉：\(error.localizedDescription, privacy: .public)")
                    }
                }
                guard (try? await timing.sleepUntil(wake)) != nil else { return }
            }
        }
    }

    func awaitOutcome(onTimeout: SendError, _ write: () async throws -> DeliveryRequest) async throws -> DeliveryRequest {
        let deadline = timing.now().addingTimeInterval(Speech.receiptLimit)
        let request = try await write()
        return try await withThrowingTaskGroup(of: DeliveryRequest.self) { [store, timing] group in
            group.addTask { try await store.outcome(of: request) }
            group.addTask {
                try await timing.sleepUntil(deadline)
                throw onTimeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func request(on host: String, _ write: () async throws -> DeliveryRequest) async throws -> DeliveryRequest {
        try await requireAwake(host)
        return try await write()
    }

    func requireAwake(_ host: String) async throws {
        guard try await store.macKnownOff(host, at: speech) != nil else { return }
        await syncing.syncNow()
        if let mac = try await store.macKnownOff(host, at: speech) { throw SendError.macOff(mac) }
    }

    func answer(_ value: AnswerValue, to session: SessionState) async throws -> DeliveryRequest {
        guard let question = session.question, question.isAnswerable, let promptID = question.promptID else {
            throw SendError.unanswerable
        }
        return try await request(on: session.hostID) {
            try await store.requestAnswer(Answer(promptID: promptID, value: value, question: question.text), to: session.target, on: session.hostID)
        }
    }

    func configure(_ config: SessionConfig, for session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestConfig(config, to: session.target, on: session.hostID) }
    }

    @discardableResult
    func rename(_ session: SessionState, to name: String) async throws -> DeliveryRequest {
        guard let name = SessionRename.clean(name) else { throw CueStoreError.blankDeliveryContent }
        return try await configure(SessionConfig(name: name), for: session)
    }

    func end(_ session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestEnd(of: session.target, on: session.hostID) }
    }

    func stop(_ session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestStop(of: session.target, on: session.hostID) }
    }

    func retry(_ session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestRetry(of: session.target, on: session.hostID) }
    }

    func launchSession(
        in project: UUID, prompt: String?, title: String, on host: String, card: UUID?, agent: AgentKind,
        model: ModelKey? = nil, thinking: ThinkingLevel? = nil, fast: Bool = false, intent: SessionLaunchIntent = .new
    ) async throws -> SessionLaunch {
        let token = UUID().uuidString
        let request = try await request(on: host) {
            try await store.requestLaunch(
                LaunchRequest(project: project, prompt: prompt, token: token, agent: agent, model: model, thinking: thinking, fast: fast),
                title: title, on: host, card: card, intent: intent)
        }
        return SessionLaunch(request: request.id, token: token)
    }

    func requestBind(_ bind: BindRequest, title: String, on host: String) async throws -> DeliveryRequest {
        try await request(on: host) { try await store.requestBind(bind, title: title, on: host) }
    }

    func requestTidy(_ orders: [TidyOrder], on host: String) async throws -> DeliveryRequest {
        try await request(on: host) { try await store.requestTidy(orders, on: host) }
    }

    func requestLibraryEdit(_ edit: LibraryEdit, title: String, on host: String) async throws -> DeliveryRequest {
        try await request(on: host) { try await store.requestLibraryEdit(edit, title: title, on: host) }
    }

    func requestTranscript(of session: SessionState) async throws -> DeliveryRequest {
        try await request(on: session.hostID) { try await store.requestTranscript(of: session) }
    }
}

nonisolated extension SessionState {
    var target: SendTarget { SendTarget(kind: .piSession, name: title, ref: sessionID) }
}
