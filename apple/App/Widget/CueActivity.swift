import Foundation
#if os(iOS)
import ActivityKit
#endif

nonisolated struct CueActivityState: Codable, Hashable, Sendable {
    var now: CueNow

    func same(as other: CueActivityState) -> Bool { now.same(as: other.now) }
}

#if os(iOS)
nonisolated struct CueActivityAttributes: ActivityAttributes {
    typealias ContentState = CueActivityState
    var startedAt: Date? = .now
    var remoteUpdates: Bool?
}
#endif
