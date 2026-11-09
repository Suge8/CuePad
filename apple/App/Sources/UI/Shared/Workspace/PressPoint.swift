import Foundation

nonisolated struct PressPoint {
    private var last: (point: CGPoint, at: ContinuousClock.Instant)?

    mutating func record(_ point: CGPoint) { last = (point, .now) }

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
