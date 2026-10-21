import Foundation

/// 窗口里最近按下的那一下（窗口坐标与时刻；Mac 的鼠标、手机的手指，由窗口的按下监听报来，`Workspace.pressed`）：任务气泡从这里长出来。
nonisolated struct PressPoint {
    private var last: (point: CGPoint, at: ContinuousClock.Instant)?

    mutating func record(_ point: CGPoint) { last = (point, .now) }

    /// 刚按下的那一下；不是刚点的（键盘、⌘K 里按 ↩、链接）没有来源，气泡在窗口上方居中。
    var source: BubbleSource {
        guard let last, Self.isFresh(last.at) else { return .unanchored }
        return .press(last.point)
    }

    /// 气泡刚在 `at` 收起、这一下又要打开它：是按在它的开关上收起的（按下就关，松开时开关又要打开它），不再打开。
    static func reopens(closedAt at: ContinuousClock.Instant?) -> Bool { at.map(isFresh) ?? false }

    /// 按下之后这么久之内打开的气泡算是这一下点开的（点按松开、读库的一跳都在里面；再久就不是这一下了）。
    private static let fresh: Duration = .milliseconds(900)

    private static func isFresh(_ at: ContinuousClock.Instant) -> Bool { ContinuousClock.now - at < fresh }
}
