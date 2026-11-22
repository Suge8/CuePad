#if os(macOS)
import CueBridge
import CueStore

extension MacExecutor {
    func end(_ request: DeliveryRequest) async throws {
        let ref = try sessionID(of: request.target)
        if let live = bridge.session(sessionID: ref) { try await bridge.end(live.id) }
        try await recorder.end(sessionID: ref, confirming: request.coveredEndRequests)
    }

    func stop(_ target: SendTarget) async throws {
        guard let id = bridge.session(sessionID: try sessionID(of: target))?.id else { return }
        try await bridge.abort(id)
    }

    /// 接着出错的那一轮重试（不写发送记录）：出错的会话在桥上才有这一轮，已结束的不唤醒（唤醒后的进程没有出错的状态，扩展不重跑）。
    func retry(_ target: SendTarget) async throws {
        guard let id = bridge.session(sessionID: try sessionID(of: target))?.id else { throw SendError.sessionNotOnThisMac(target.name) }
        try await bridge.retry(id)
    }

    func sessionID(of target: SendTarget) throws -> String {
        guard target.kind == .known(.piSession) else { throw SendError.unsupportedTarget(target.name) }
        guard let ref = target.ref else { throw SendError.sessionNotOnThisMac(target.name) }
        return ref
    }

}
#endif
