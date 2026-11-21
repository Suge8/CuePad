import Foundation

nonisolated enum DarwinNotifications {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    static func notifications(named name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let observer = Observer(continuation)
            let pointer = Unmanaged.passRetained(observer).toOpaque()
            let address = UInt(bitPattern: pointer)
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), pointer,
                { _, pointer, _, _, _ in
                    guard let pointer else { return }
                    Unmanaged<Observer>.fromOpaque(pointer).takeUnretainedValue().continuation.yield()
                },
                name as CFString, nil, .deliverImmediately)
            continuation.onTermination = { _ in
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                CFNotificationCenterRemoveObserver(
                    CFNotificationCenterGetDarwinNotifyCenter(), pointer, CFNotificationName(name as CFString), nil)
                Unmanaged<Observer>.fromOpaque(pointer).release()
            }
        }
    }

    private final class Observer: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }
}
