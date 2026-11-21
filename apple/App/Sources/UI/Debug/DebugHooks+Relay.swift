import Foundation

/// 调试断中转（`-CuePadVoiceDropRelay`，`DebugRelayDrop`）伸进 `Relay` 的钩子；Release 里什么都不做。
extension DebugHooks {
    static func relaySocket(_ socket: URLSessionWebSocketTask) {
        #if DEBUG
        DebugRelayDrop.socket = socket
        #endif
    }

    static func relayHold() async {
        #if DEBUG
        await DebugRelayDrop.hold()
        #endif
    }
}

#if DEBUG
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
