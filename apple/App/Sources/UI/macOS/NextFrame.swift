#if os(macOS)
import AppKit

/// 等到屏幕下一次刷新：分几帧做的事，每一步的改动落在自己那一帧里（上一步已经提交）。
/// 主队列异步不行：它有时排在同一次提交之前，几步又挤回一帧。
/// 窗口被遮挡时刷新不来：等待的任务被取消就立刻醒来，不悬着。
enum NextFrame {
    static func wait() async {
        let tick = Tick()
        await withTaskCancellationHandler {
            await withCheckedContinuation { tick.start($0) }
        } onCancel: {
            Task { @MainActor in tick.finish() }
        }
    }

    private final class Tick: NSObject {
        private var link: CADisplayLink?
        private var continuation: CheckedContinuation<Void, Never>?

        func start(_ continuation: CheckedContinuation<Void, Never>) {
            guard let screen = NSScreen.main else { return continuation.resume() }
            self.continuation = continuation
            link = screen.displayLink(target: self, selector: #selector(fire))
            link?.add(to: .main, forMode: .common)
        }

        @objc func fire(_ link: CADisplayLink) { finish() }

        func finish() {
            link?.invalidate()
            link = nil
            continuation?.resume()
            continuation = nil
        }
    }
}
#endif
