import CueStore
import Foundation
import Observation

@Observable
final class CueFeed {
    typealias Read = CueReading.Read

    nonisolated struct Seen: Sendable {
        var read: Read
        var moment: Speech.Moment
        var local: CueNow.Local
    }

    private(set) var read: Read?
    fileprivate(set) var failure: (any Error)?
    @ObservationIgnored fileprivate var following = false
    @ObservationIgnored private var start: Snapshot<Read>?
    @ObservationIgnored private let store: CueStore
    private let widget: Bool

    init(store: CueStore, widget: Bool) {
        self.store = store
        self.widget = widget
    }

    func latest() -> Read? {
        if let read { return read }
        start = try? store.snapshot { [widget] in try Read.read(from: $0, widget: widget) }
        return start?.value
    }

    fileprivate func follow() async {
        defer { following = false }
        let read: @Sendable (isolated CueStore) throws -> Read = { [widget] in try Read.read(from: $0, widget: widget) }
        if let start { self.read = start.value }
        do {
            for try await next in start.map({ store.observe(from: $0, read) }) ?? store.observe(read) { self.read = next }
        } catch {
            failure = error
        }
    }

    fileprivate func updates(_ services: AppServices) -> AsyncThrowingStream<Seen, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await (read, moment, local, failure, _) in Observations({ (self.read, services.speech, services.cueLocal, self.failure, DebugHooks.cueNow) }) {
                    if let failure { return continuation.finish(throwing: failure) }
                    if let read { continuation.yield(Seen(read: read, moment: moment, local: local)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AppServices {
    func cueUpdates() -> AsyncThrowingStream<CueFeed.Seen, any Error> {
        if !cueFeed.following {
            cueFeed.following = true
            cueFeed.failure = nil
            follow { await self.cueFeed.follow() }
        }
        return cueFeed.updates(self)
    }
}
