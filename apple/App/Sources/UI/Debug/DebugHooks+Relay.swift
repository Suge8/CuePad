import Foundation

/// 调试断中转（`-CuePadVoiceDropRelay`，`DebugRelayDrop`）伸进 `Relay` 的钩子；Release 里什么都不做。
extension DebugHooks {
    /// 每条新连接建好时登记，断的就是它。
    static func relaySocket(_ socket: URLSessionWebSocketTask) {
        #if DEBUG
        DebugRelayDrop.socket = socket
        #endif
    }

    /// 重连前等到断开的时长过完。
    static func relayHold() async {
        #if DEBUG
        await DebugRelayDrop.hold()
        #endif
    }
}

#if DEBUG
/// 像网络断了一样断掉中转连接，并在给定时长内不重连。
enum DebugRelayDrop {
    static weak var socket: URLSessionWebSocketTask?
    private static var heldUntil: ContinuousClock.Instant?

    static func drop(for duration: Duration) {
        heldUntil = .now + duration
        socket?.cancel(with: .goingAway, reason: nil)
    }

    static func hold() async {
        guard let until = heldUntil else { return }
        try? await Task.sleep(until: until, clock: .continuous)
        heldUntil = nil
    }
}
#endif
