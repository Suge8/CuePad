import Foundation

nonisolated struct PressPoint {
    private var last: (point: CGPoint, at: ContinuousClock.Instant)?
    /// 项目页任务清单那一栏在窗口里的横向范围（`ProjectTasks` 报，页不在前面时为 nil）；下界已经让出气泡里圈之前那一截：
    /// 按在这一栏里点开的气泡左沿贴着它，气泡里的圈与标题正落在清单的圈与标题那两列上，像这一行就地展开。
    var lane: ClosedRange<CGFloat>?

    mutating func record(_ point: CGPoint) { last = (point, .now) }

    var source: BubbleSource {
        guard let last, Self.isFresh(last.at) else { return .unanchored }
        return .press(last.point, left: lane.flatMap { $0.contains(last.point.x) ? $0.lowerBound : nil })
    }

    /// 气泡刚在 `at` 收起、这一下又要打开它：是按在它的开关上收起的（按下就关，松开时开关又要打开它），不再打开。
    static func reopens(closedAt at: ContinuousClock.Instant?) -> Bool { at.map(isFresh) ?? false }

    /// 按下之后这么久之内打开的气泡算是这一下点开的（点按松开、读库的一跳都在里面；再久就不是这一下了）。
    private static let fresh: Duration = .milliseconds(900)

    private static func isFresh(_ at: ContinuousClock.Instant) -> Bool { ContinuousClock.now - at < fresh }
}
