#if os(macOS)
import CuePi
import CueStore

extension MacExecutor {
    /// 结束会话（不写发送记录）：在桥上的先关掉它的进程；不在桥上的（托管着、进程已歇的，或早已结束的）没有进程可关，
    /// 不能为了结束它而恢复它。两种都由这里记为已结束、进历史——托管的会话闲置退出不算结束，只有用户的结束请求才算。
    func end(_ target: SendTarget) async throws {
        let ref = try sessionID(of: target)
        if let live = pi.session(sessionID: ref) { try await pi.end(live.id) }
        try await recorder.end(sessionID: ref)
    }

    /// 停止这一轮（不写发送记录）：不在这台 Mac 的桥上的已经没有这一轮，目标达成，不恢复它。
    func stop(_ target: SendTarget) async throws {
        guard let id = pi.session(sessionID: try sessionID(of: target))?.id else { return }
        try await pi.abort(id)
    }

    /// 接着出错的那一轮重试（不写发送记录）：出错的会话在桥上才有这一轮，已结束的不唤醒（唤醒后的进程没有出错的状态，扩展不重跑）。
    func retry(_ target: SendTarget) async throws {
        guard let id = pi.session(sessionID: try sessionID(of: target))?.id else { throw SendError.sessionNotOnThisMac(target.name) }
        try await pi.retry(id)
    }

    /// 请求指名的 Pi 会话（Pi 自己的会话 id）；别的目标是旧版本写的发到应用、剪贴板，按失败写回。
    func sessionID(of target: SendTarget) throws -> String {
        guard target.kind == .known(.piSession) else { throw SendError.unsupportedTarget(target.name) }
        guard let ref = target.ref else { throw SendError.sessionNotOnThisMac(target.name) }
        return ref
    }

}
#endif
