import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 等到屏幕下一次刷新：分几帧做的事，每一步的改动落在自己那一帧里（上一步已经提交）。
/// 主队列异步不行：它有时排在同一次提交之前，几步又挤回一帧。
/// 窗口被遮挡时刷新不来：等待的任务被取消就立刻醒来，不悬着。
enum NextFrame {
    /// 这一次更新画上屏之后：SwiftUI 按自己的刷新回调画，与这里的刷新谁先谁后不定，下一次刷新可能还排在它画这一帧之前，
    /// 等过两次刷新才一定画过。打开页面后紧接着要做的重活（往上再排开一段、出缩略图）等它，不挤进页面出来的那一帧。
    static func drawn() async {
        await wait()
        await wait()
    }

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
            #if os(macOS)
            guard let screen = NSScreen.main else { return continuation.resume() }
            link = screen.displayLink(target: self, selector: #selector(fire))
            #else
            link = CADisplayLink(target: self, selector: #selector(fire))
            #endif
            self.continuation = continuation
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
