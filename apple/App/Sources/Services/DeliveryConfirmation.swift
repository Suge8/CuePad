#if os(macOS)
import CueBridge
import CueStore
import Foundation

/// 只核对真实历史，不起 Agent、不发消息。任务由 DeliveryExecutor 持有，停止时取消并收齐。
/// 交出后话出现在会话文件里才算送达（`Session.confirmsFromHistory`）；期限内没出现按未确认收尾，之后出现了索引照样改成送达。
struct DeliveryConfirmation {
    let store: CueStore
    let bridge: Bridge

    func pending(in session: CueBridge.Session, reason: ShownText? = nil) -> DeliveryOutcome {
        .confirming { request in
            do {
                if let file = session.sessionFile {
                    // 桥给出的文件位置是事实，尚未读到文件不等于消息已落盘；检查点仍为空。
                    try await store.seedSession(IndexedSession(
                        id: session.sessionID, path: file.path, cwd: session.cwd.path, title: session.displayName,
                        lastActivityAt: session.stateSince, agent: session.agent), host: request.hostID)
                }
                return await verify(request, session: session.sessionID, agent: session.agent, connection: session.id, file: session.sessionFile, reason: reason)
            } catch { return await unresolved(error) }
        }
    }

    func recover(_ request: DeliveryRequest) async -> DeliveryOutcome {
        do {
            guard request.mode == .known(.send) || request.mode == .known(.start) else { return .unconfirmed(DeliveryRequest.interruptedReason) }
            let sessionID: String?
            if let ref = request.target.ref { sessionID = ref }
            else if let token = request.launch?.token {
                sessionID = try await store.sessionPage(.init(launchToken: token, limit: 1)).items.first?.state.sessionID
            } else { sessionID = nil }
            guard let sessionID else { return .unconfirmed(DeliveryRequest.interruptedReason) }
            if let session = bridge.session(sessionID: sessionID) {
                guard session.confirmsFromHistory else { return .unconfirmed(DeliveryRequest.interruptedReason) }
                return pending(in: session, reason: request.reason)
            }
            // 重开时会话多半还没回到桥上：按索引里的会话文件接着核对
            guard let indexed = try await store.indexedSession(sessionID), indexed.agent.confirmsFromHistory else {
                return .unconfirmed(DeliveryRequest.interruptedReason)
            }
            return .confirming { current in
                await verify(current, session: indexed.id, agent: indexed.agent, connection: nil, file: URL(filePath: indexed.path), reason: request.reason)
            }
        } catch { return unresolved(error) }
    }

    private func verify(
        _ request: DeliveryRequest, session: String, agent: AgentKind, connection: CueBridge.Session.ID?, file: URL?, reason: ShownText?
    ) async -> DeliveryOutcome {
        let uncertain = reason ?? Speech.unconfirmedReason
        guard let file else { return .unconfirmed(uncertain) }
        let source = HistorySource(session: session, agent: agent, file: file)
        do {
            return try await inspect(request, source, connection: connection, uncertain: uncertain)
        } catch is CancellationError {
            return .unconfirmed(uncertain)
        } catch {
            return unresolved(error)
        }
    }

    private func unresolved(_ error: any Error) -> DeliveryOutcome {
        AppServices.log.error("核对投送历史失败：\(String(describing: error), privacy: .public)")
        return .unconfirmed(ShownText(error))
    }

    /// 跟着文件读是 Pi 的历史索引的事（未收尾投送的文件它一直跟着，`deliveryHistoryFiles`），收下的话由它写成送达；
    /// 这里只在开头与断线时各补读一次，从索引存下的检查点接着读，不从头读整个会话文件。
    private func inspect(
        _ request: DeliveryRequest, _ source: HistorySource, connection: CueBridge.Session.ID?, uncertain: ShownText
    ) async throws -> DeliveryOutcome {
        if try await received(request) { return .succeeded }
        try await look(source)
        if try await received(request) { return .succeeded }
        try Task.checkCancellation()
        // 到期只在 `wait` 的计时里判：走到这里已过期限的（读会话文件慢、交出后 Mac 睡了）在那里当场到期，同样先看它还在不在跑
        guard let deadline = request.deadlineAt else { return .unconfirmed(uncertain) }
        if let connection, bridge.session(id: connection) == nil { return try await lastLook(request, source, uncertain: uncertain) }
        return try await wait(request, source, connection: connection, until: deadline, uncertain: uncertain)
    }

    private func received(_ request: DeliveryRequest) async throws -> Bool {
        try await store.deliveryRequest(request.id)?.status == .known(.succeeded)
    }

    private func wait(
        _ request: DeliveryRequest, _ source: HistorySource, connection: CueBridge.Session.ID?, until deadline: Date, uncertain: ShownText
    ) async throws -> DeliveryOutcome {
        try await withThrowingTaskGroup(of: DeliveryOutcome.self) { group in
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
                    // 在跑这一轮时送到的话，Agent 排到这一轮结束才收：到期时还在跑就接着等，不当成没收下。
                    // 只在这里等、不改库里的期限：同步不让核对期限往后挪（`DeliveryRequest.mergingProgress`），各端到期先显示送达未确认，收下了再变送达
                    guard let connection, await bridge.isTurnRunning(connection) else { return .unconfirmed(uncertain) }
                    due = store.timing.now().addingTimeInterval(Speech.receiptLimit)
                }
            }
            if let connection {
                let changes = bridge.changes()
                group.addTask {
                    for await _ in changes {
                        if await bridge.session(id: connection) != nil { continue }
                        return try await lastLook(request, source, uncertain: uncertain)
                    }
                    throw CancellationError()
                }
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// 断线时最后核对一次：文件可能已写好，只是索引还没读到。首读之后、等待之前就断了的同样要读，不能直接按没收下收尾。
    private func lastLook(_ request: DeliveryRequest, _ source: HistorySource, uncertain: ShownText) async throws -> DeliveryOutcome {
        try await look(source)
        return try await received(request) ? .succeeded : .unconfirmed(uncertain)
    }

    /// 从索引存下的检查点接着读（读不懂的旧检查点当没有）；之前的内容索引已写过。
    private struct HistorySource {
        let session: String
        let agent: AgentKind
        let file: URL
    }

    @concurrent private func look(_ source: HistorySource) async throws {
        let checkpoint = try await store.checkpoint(of: source.session).flatMap { try? JSONDecoder().decode(HistoryCheckpoint.self, from: $0) }
        do {
            let update = try History.index(file: source.file, agent: source.agent, from: checkpoint, files: store.files)
            try await store.writeDeliveryReceipts(update.messages)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return
        }
    }
}
#endif
