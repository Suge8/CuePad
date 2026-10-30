#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 只核对真实历史，不起 Agent、不发消息。任务由 DeliveryExecutor 持有，停止时取消并收齐。
struct PiDeliveryConfirmation {
    let store: CueStore
    let pi: PiBridge

    func pending(in session: CuePi.PiSession, reason: ShownText? = nil) -> DeliveryOutcome {
        .confirming { request in
            do {
                if let file = session.sessionFile, try await store.piSession(session.sessionID) == nil {
                    // 桥给出的文件位置是事实，尚未读到文件不等于消息已落盘；检查点仍为空。
                    try await store.upsertPiSession(IndexedSession(
                        id: session.sessionID, path: file.path, cwd: session.cwd.path, title: session.displayName,
                        lastActivityAt: session.stateSince), host: request.hostID)
                }
                return await verify(request, connection: session.id, file: session.sessionFile, reason: reason)
            } catch { return await unresolved(error) }
        }
    }

    func recover(_ request: DeliveryRequest) async -> DeliveryOutcome {
        guard request.mode == .known(.send) || request.mode == .known(.start) else { return .unconfirmed(DeliveryRequest.interruptedReason) }
        do {
            let sessionID: String?
            if let ref = request.target.ref { sessionID = ref }
            else if let token = request.launch?.token {
                sessionID = try await store.piSessionPage(.init(launchToken: token, limit: 1)).items.first?.state.sessionID
            } else { sessionID = nil }
            guard let sessionID else { return .unconfirmed(DeliveryRequest.interruptedReason) }
            if let session = pi.session(sessionID: sessionID) {
                guard session.agent == .pi else { return .unconfirmed(DeliveryRequest.interruptedReason) }
                return pending(in: session, reason: request.failureReason)
            }
            let indexed = try await store.piSession(sessionID)
            guard indexed?.agent == .pi else { return .unconfirmed(DeliveryRequest.interruptedReason) }
            return .confirming { current in
                await verify(current, connection: nil, file: indexed.map { URL(filePath: $0.path) }, reason: request.failureReason)
            }
        } catch { return unresolved(error) }
    }

    private func verify(
        _ request: DeliveryRequest, connection: CuePi.PiSession.ID?, file: URL?, reason: ShownText?
    ) async -> DeliveryOutcome {
        let uncertain = reason ?? Speech.unconfirmedReason
        guard let file else { return .unconfirmed(uncertain) }
        let following = PiHistory.following(file: file, agent: .pi, files: store.files)
        let result: DeliveryOutcome
        do {
            result = try await inspect(request, history: following.updates, connection: connection, file: file, uncertain: uncertain)
        } catch is CancellationError { result = .unconfirmed(uncertain) }
        catch {
            result = unresolved(error)
        }
        await following.stop()
        return result
    }

    private func unresolved(_ error: any Error) -> DeliveryOutcome {
        AppServices.log.error("核对投送历史失败：\(String(describing: error), privacy: .public)")
        return .unconfirmed(ShownText(error))
    }

    private func inspect(
        _ request: DeliveryRequest, history: AsyncThrowingStream<PiHistoryUpdate?, Error>, connection: CuePi.PiSession.ID?, file: URL, uncertain: ShownText
    ) async throws -> DeliveryOutcome {
        if try await received(request) { return .succeeded }
        // 首份是定点核对；先读再判断旧记录、到期或失联，不把缺期限当作未交出。
        if let first = try await history.first(where: { @Sendable _ in true }), let first {
            try await store.writePiDeliveryReceipts(first.messages)
        }
        if try await received(request) { return .succeeded }
        try Task.checkCancellation()
        guard let deadline = request.deadlineAt, store.timing.now() < deadline else { return .unconfirmed(uncertain) }
        if let connection, pi.session(id: connection) == nil { return .unconfirmed(uncertain) }
        return try await wait(request, history: history, connection: connection, file: file, until: deadline, uncertain: uncertain)
    }

    private func received(_ request: DeliveryRequest) async throws -> Bool {
        try await store.deliveryRequest(request.id)?.status == .known(.succeeded)
    }

    private func wait(
        _ request: DeliveryRequest, history: AsyncThrowingStream<PiHistoryUpdate?, Error>, connection: CuePi.PiSession.ID?, file: URL,
        until deadline: Date, uncertain: ShownText
    ) async throws -> DeliveryOutcome {
        try await withThrowingTaskGroup(of: DeliveryOutcome.self) { group in
            group.addTask {
                for try await update in history {
                    if let update { try await store.writePiDeliveryReceipts(update.messages) }
                    if try await received(request) { return .succeeded }
                }
                throw CancellationError()
            }
            group.addTask {
                for try await current in store.observe({ try $0.deliveryRequest(request.id) }) {
                    if current?.status == .known(.succeeded) { return .succeeded }
                    if current == nil { throw CancellationError() }
                }
                throw CancellationError()
            }
            group.addTask {
                try await store.timing.sleepUntil(deadline)
                return .unconfirmed(uncertain)
            }
            if let connection {
                let changes = pi.changes()
                group.addTask {
                    for await _ in changes {
                        if await pi.session(id: connection) != nil { continue }
                        // 断线时最后核对一次：文件可能已写好，只是常规摄取尚未提交。
                        try await readLast(file)
                        return try await received(request) ? .succeeded : .unconfirmed(uncertain)
                    }
                    throw CancellationError()
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    @concurrent private func readLast(_ file: URL) async throws {
        do {
            let update = try PiHistory.index(file: file, agent: .pi, from: nil, files: store.files)
            try await store.writePiDeliveryReceipts(update.messages)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
    }
}
#endif
