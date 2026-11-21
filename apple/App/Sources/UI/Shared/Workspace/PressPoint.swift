import Foundation

nonisolated struct PressPoint {
    private var last: (point: CGPoint, at: ContinuousClock.Instant)?
    var lane: ClosedRange<CGFloat>?

    mutating func record(_ point: CGPoint) { last = (point, .now) }

    var source: BubbleSource {
        guard let last, Self.isFresh(last.at) else { return .unanchored }
        return .press(last.point, left: lane.flatMap { $0.contains(last.point.x) ? $0.lowerBound : nil })
    }

    static func reopens(closedAt at: ContinuousClock.Instant?) -> Bool { at.map(isFresh) ?? false }

    private static let fresh: Duration = .milliseconds(900)

    private static func isFresh(_ at: ContinuousClock.Instant) -> Bool { ContinuousClock.now - at < fresh }
}
