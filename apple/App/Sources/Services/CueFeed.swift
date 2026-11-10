import CueStore
import Foundation
import Observation

/// Cue 那一行、小组件快照与实时活动都从这里取，整个界面一份、共用订阅读一次，不各自订阅、库一变各读一遍摘要。
/// 原始共享读取归 `CueReading`；发布者直接订阅它，不以这里的界面观察为前置。
/// 读失败时订阅结束、记下错误，读它的各自报出。
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
    /// 订阅还没读到时当场读的那份：订阅从它接着读，不重读
    @ObservationIgnored private var start: Snapshot<Read>?
    @ObservationIgnored private let store: CueStore
    private let widget: Bool

    init(store: CueStore, widget: Bool) {
        self.store = store
        self.widget = widget
    }

    /// 新建的窗口第一帧就是它；读不出来为 nil（失败页盖住页面）。
    func latest() -> Read? {
        if let read { return read }
        start = try? store.snapshot { [widget] in try Read.read(from: $0, widget: widget) }
        return start?.value
    }

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

    /// 在调用方的任务里跟到被取消，每份交给 `each`；订阅读失败时抛那个错误。消费慢时跳过中间的，交的总是最新那份。
    fileprivate func updates(_ services: AppServices, _ each: (Seen) async throws -> Void) async throws {
        for await (read, moment, local, failure) in Observations({ (self.read, services.speech, services.cueLocal, self.failure) }) {
            if let failure { throw failure }
            if let read { try await each(Seen(read: read, moment: moment, local: local)) }
        }
    }
}

extension AppServices {
    /// 第一个来读的起订阅（随 App 的常驻任务一起取消），之后的共用。
    func cueUpdates(_ each: (CueFeed.Seen) async throws -> Void) async throws {
        if !cueFeed.following {
            cueFeed.following = true
            cueFeed.failure = nil
            follow { await self.cueFeed.follow() }
        }
        try await cueFeed.updates(self, each)
    }
}
