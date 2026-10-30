import CueStore
import Foundation

/// UI 与发布各自直接订阅 Store 的同一份纯事实。读取与推进不经过 CueFeed、MainActor 或界面 Observations。
nonisolated struct CueReading: Sendable {
    struct Read: Equatable, Sendable {
        let digest: CueDigest
        let widget: WidgetContent?
        let activity: ActivityRead?

        static func read(from store: isolated CueStore, widget: Bool) throws -> Read {
            let destinations = widget ? [] : try store.activityDestinations()
            return Read(
                digest: try CueDigest.read(from: store), widget: widget ? try store.widgetContent() : nil,
                activity: destinations.isEmpty ? nil : ActivityRead(destinations: destinations, publisher: try store.activityPublisher()))
        }
    }

    struct ActivityRead: Equatable, Sendable {
        let destinations: [ActivityDestination]
        let publisher: String?
    }

    let store: CueStore
    let widget: Bool

    func updates() -> AsyncThrowingStream<Read, any Error> {
        store.observe { [widget] in try Read.read(from: $0, widget: widget) }
    }

    func read() async throws -> Read { try await Read.read(from: store, widget: widget) }
}
