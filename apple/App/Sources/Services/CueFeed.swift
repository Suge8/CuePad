import CueStore
import Foundation
import Observation

/// Cue 的现状：库里那页摘要（`CueDigest`）配上此刻与本机事实（`AppServices.observeCue`），整个 App 一份、一个订阅读一次（同 `LiveSessions`）。
/// Cue 那一行（`CueWatch`，每个窗口一份）与 iPhone 的小组件快照、实时活动（`startSnapshots`）都从这里取，不各自订阅、库一变各读一遍摘要；
/// iPhone 上同一次读顺带读小组件另要的项目、默认项目与额度（`WidgetContent`，`widget`）。
/// 第一个来读的起订阅（`AppServices.cueUpdates`），之后的共用；读失败时订阅结束、记下错误，读它的各自报出。
@Observable
final class CueFeed {
    nonisolated struct Read: Equatable, Sendable {
        var digest: CueDigest
        /// 小组件另要的（只有 iPhone 读）
        var widget: WidgetContent?

        static func read(from store: isolated CueStore, widget: Bool) throws -> Read {
            Read(digest: try CueDigest.read(from: store), widget: widget ? try store.widgetContent() : nil)
        }
    }

    nonisolated struct Seen: Sendable {
        var read: Read
        var moment: Speech.Moment
        var local: CueNow.Local
    }

    /// 订阅读到的最近一份；还没读到为 nil。
    private(set) var seen: Seen?
    fileprivate(set) var failure: (any Error)?
    @ObservationIgnored fileprivate var following = false
    /// 订阅还没读到时当场读的那份：订阅从它接着读，不重读
    @ObservationIgnored private var start: Snapshot<Read>?
    @ObservationIgnored private let store: CueStore
    private let widget: Bool

    init(store: CueStore, widget: Bool) {
        self.store = store
        self.widget = widget
    }

    /// 手里最新的一份（新建的窗口第一帧就是它）：订阅读到的；还没读到就当场读，读不出来为 nil（失败页盖住页面）。
    func latest() -> Read? {
        if let seen { return seen.read }
        start = try? store.snapshot { [widget] in try Read.read(from: $0, widget: widget) }
        return start?.value
    }

    /// 跟随资料库、此刻与本机事实，直到任务取消或读失败。
    fileprivate func follow(_ services: AppServices) async {
        defer { following = false }
        do {
            for try await (read, moment, local) in services.observeCue(from: start, { [widget] in try Read.read(from: $0, widget: widget) }) {
                seen = Seen(read: read, moment: moment, local: local)
            }
        } catch {
            failure = error
        }
    }

    /// 手里这份与之后的每一份；订阅读失败时以那个错误结束。
    fileprivate func updates() -> AsyncThrowingStream<Seen, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await (seen, failure) in Observations({ (self.seen, self.failure) }) {
                    if let failure { return continuation.finish(throwing: failure) }
                    if let seen { continuation.yield(seen) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AppServices {
    /// Cue 的现状的每一份（`CueFeed`）：第一个来读的起订阅（随 App 的常驻任务一起取消），之后的共用它。
    func cueUpdates() -> AsyncThrowingStream<CueFeed.Seen, any Error> {
        if !cueFeed.following {
            cueFeed.following = true
            cueFeed.failure = nil
            follow { await self.cueFeed.follow(self) }
        }
        return cueFeed.updates()
    }
}
