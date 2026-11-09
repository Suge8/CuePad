#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 只核对真实历史，不起 Agent、不发消息。任务由 DeliveryExecutor 持有，停止时取消并收齐。
/// 交出后话出现在会话文件里才算送达（`PiSession.confirmsFromHistory`）；期限内没出现按未确认收尾，之后出现了索引照样改成送达。
struct PiDeliveryConfirmation {
    let store: CueStore
    let pi: PiBridge

    /// 终端里的 Claude Code 到期没把话写进会话文件：它没说为什么，常见的是这两种（`PiSession.confirmsFromHistory`）
    static let notTaken = ShownText("Claude Code 没有收下这句话：可能在它的终端里等你批准，或被它的设置（crossSessionInbound）挡下了。去终端里看一眼，CuePad 不会自动重发")

    func pending(in session: CuePi.PiSession, reason: ShownText? = nil) -> DeliveryOutcome {
        .confirming { request in
            do {
                if let file = session.sessionFile {
                    // 桥给出的文件位置是事实，尚未读到文件不等于消息已落盘；检查点仍为空。
                    try await store.seedPiSession(IndexedSession(
                        id: session.sessionID, path: file.path, cwd: session.cwd.path, title: session.displayName,
                        lastActivityAt: session.stateSince, agent: session.agent), host: request.hostID)
                }
                return await verify(request, agent: session.agent, connection: session.id, file: session.sessionFile, reason: reason)
            } catch { return await unresolved(error) }
        }
    }

    func recover(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            guard request.mode == .known(.send) || request.mode == .known(.start) else { return .unconfirmed(DeliveryRequest.interruptedReason) }
            let sessionID: String?
            if let ref = request.target.ref { sessionID = ref }
            else if let token = request.launch?.token {
                sessionID = try await store.piSessionPage(.init(launchToken: token, limit: 1)).items.first?.state.sessionID
            } else { sessionID = nil }
            guard let sessionID else { return .unconfirmed(DeliveryRequest.interruptedReason) }
            if let session = pi.session(sessionID: sessionID) {
                guard session.confirmsFromHistory else { return .unconfirmed(DeliveryRequest.interruptedReason) }
                return pending(in: session, reason: request.reason)
            }
            // 重开时会话多半还没回到桥上：按索引里的会话文件接着核对
            let hosted = try await store.sessionState(sessionID)?.hosted ?? false
            guard let indexed = try await store.piSession(sessionID), indexed.agent.confirmsFromHistory(hosted: hosted) else {
                return .unconfirmed(DeliveryRequest.interruptedReason)
            }
            return .confirming { current in
                await verify(current, agent: indexed.agent, connection: nil, file: URL(filePath: indexed.path), reason: request.reason)
            }
        } catch { return unresolved(error) }
    }

    private func verify(
        _ request: DeliveryRequest, agent: AgentKind, connection: CuePi.PiSession.ID?, file: URL?, reason: ShownText?
    ) async -> DeliveryOutcome {
        let uncertain = reason ?? (agent == .pi ? Speech.unconfirmedReason : Self.notTaken)
        guard let file else { return .unconfirmed(uncertain) }
        let following = PiHistory.following(file: file, agent: agent, files: store.files)
        let result: DeliveryOutcome
        do {
            result = try await inspect(request, agent: agent, history: following.updates, connection: connection, file: file, uncertain: uncertain)
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
        _ request: DeliveryRequest, agent: AgentKind, history: AsyncThrowingStream<PiHistoryUpdate?, Error>, connection: CuePi.PiSession.ID?, file: URL,
        uncertain: ShownText
    ) async throws -> DeliveryOutcome {
        if try await received(request) { return .succeeded }
        // 首份是定点核对；先读再判断旧记录、到期或失联，不把缺期限当作未交出。
        if let first = try await history.first(where: { @Sendable _ in true }), let first {
            try await store.writePiDeliveryReceipts(first.messages)
        }
        if try await received(request) { return .succeeded }
        try Task.checkCancellation()
        guard let deadline = request.deadlineAt, store.timing.now() < deadline else { return .unconfirmed(uncertain) }
        if let connection, pi.session(id: connection) == nil { return try await lastLook(request, file: file, agent: agent, uncertain: uncertain) }
        return try await wait(request, agent: agent, history: history, connection: connection, file: file, until: deadline, uncertain: uncertain)
    }

    private func received(_ request: DeliveryRequest) async throws -> Bool {
        try await store.deliveryRequest(request.id)?.status == .known(.succeeded)
    }

    private func wait(
        _ request: DeliveryRequest, agent: AgentKind, history: AsyncThrowingStream<PiHistoryUpdate?, Error>, connection: CuePi.PiSession.ID?, file: URL,
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
                var due = deadline
                while true {
                    try await store.timing.sleepUntil(due)
                    // 在跑这一轮时送到的话，Claude Code 排到这一轮结束才收：到期时还在跑就接着等，不当成没收下。
                    // 只在这里等、不改库里的期限：同步不让核对期限往后挪（`DeliveryRequest.mergingProgress`），各端到期先显示送达未确认，收下了再变送达
                    guard let connection, await pi.isTurnRunning(connection) else { return .unconfirmed(uncertain) }
                    due = store.timing.now().addingTimeInterval(Speech.receiptLimit)
                }
            }
            if let connection {
                let changes = pi.changes()
                group.addTask {
                    for await _ in changes {
                        if await pi.session(id: connection) != nil { continue }
                        return try await lastLook(request, file: file, agent: agent, uncertain: uncertain)
                    }
                    throw CancellationError()
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// 断线时最后核对一次：文件可能已写好，只是常规摄取尚未提交。首读之后、等待之前就断了的同样要读，不能直接按没收下收尾。
    private func lastLook(_ request: DeliveryRequest, file: URL, agent: AgentKind, uncertain: ShownText) async throws -> DeliveryOutcome {
        try await readLast(file, agent: agent)
        return try await received(request) ? .succeeded : .unconfirmed(uncertain)
    }

    @concurrent private func readLast(_ file: URL, agent: AgentKind) async throws {
        do {
            let update = try PiHistory.index(file: file, agent: agent, from: nil, files: store.files)
            try await store.writePiDeliveryReceipts(update.messages)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
    }
}
#endif
