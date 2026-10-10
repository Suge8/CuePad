#if os(macOS)
import AppKit

/// 等到屏幕下一次刷新：分几帧做的事，每一步的改动落在自己那一帧里（上一步已经提交）。
/// 主队列异步不行：它有时排在同一次提交之前，几步又挤回一帧。
@MainActor
enum NextFrame {
    static func wait() async {
        await withCheckedContinuation { continuation in
            guard let screen = NSScreen.main else { return continuation.resume() }
            let link = screen.displayLink(target: Tick(continuation), selector: #selector(Tick.fire))
            link.add(to: .main, forMode: .common)
        }
    }

    private final class Tick: NSObject {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

        @objc func fire(_ link: CADisplayLink) {
            link.invalidate()
            continuation?.resume()
            continuation = nil
        }
    }
}
#endif
