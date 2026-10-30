import CueStore
import Foundation
import Observation

/// Cue 的现状：库里那页摘要（`CueDigest`）配上此刻（`AppServices.speech`）与本机事实（`AppServices.cueLocal`），整个界面一份、共用订阅读一次（同 `LiveSessions`）。
/// 读的东西不随此刻与本机事实变：库变了重读，此刻或本机事实变了把手里那份配上新的再给一次（`updates`）。
/// Cue 那一行（`CueWatch`，每个窗口一份）与 iPhone 的小组件快照、实时活动（`startSnapshots`）都从这里取，不各自订阅、库一变各读一遍摘要；
/// iPhone 上同一次读顺带读小组件另要的项目、默认项目（`WidgetContent`，`widget`）。
/// 原始共享读取归 `CueReading`；发布者直接订阅它，不以这里的界面观察为前置。
/// 第一个来读的起订阅（`AppServices.cueUpdates`），之后的共用；读失败时订阅结束、记下错误，读它的各自报出。
@Observable
final class CueFeed {
    typealias Read = CueReading.Read

    nonisolated struct Seen: Sendable {
        var read: Read
        var moment: Speech.Moment
        var local: CueNow.Local
    }

    /// 订阅读到的最近一份；还没读到为 nil。
    private(set) var read: Read?
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
        if let read { return read }
        start = try? store.snapshot { [widget] in try Read.read(from: $0, widget: widget) }
        return start?.value
    }

    /// 跟随资料库，直到任务取消或读失败。
    fileprivate func follow() async {
        defer { following = false }
        let read: @Sendable (isolated CueStore) throws -> Read = { [widget] in try Read.read(from: $0, widget: widget) }
        // 从当场读的那份接着订阅时，库不变就不再给一份：先把它记成手里的，本机事实（同步对没对过）变了照样配上它再给（`updates`）
        if let start { self.read = start.value }
        do {
            for try await next in start.map({ store.observe(from: $0, read) }) ?? store.observe(read) { self.read = next }
        } catch {
            failure = error
        }
    }

    /// 手里这份与之后的每一份，配上此刻与本机事实；订阅读失败时以那个错误结束。
    fileprivate func updates(_ services: AppServices) -> AsyncThrowingStream<Seen, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await (read, moment, local, failure) in Observations({ (self.read, services.speech, services.cueLocal, self.failure) }) {
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
    /// Cue 的现状的每一份（`CueFeed`）：第一个来读的起订阅（随 App 的常驻任务一起取消），之后的共用它。
    func cueUpdates() -> AsyncThrowingStream<CueFeed.Seen, any Error> {
        if !cueFeed.following {
            cueFeed.following = true
            cueFeed.failure = nil
            follow { await self.cueFeed.follow() }
        }
        return cueFeed.updates(self)
    }
}
