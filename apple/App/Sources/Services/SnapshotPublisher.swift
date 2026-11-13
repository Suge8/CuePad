import CueStore
import Foundation
#if os(iOS)
import WidgetKit
#endif

/// 小组件的快照（共享容器里的文件）与跟着 Cue 此刻发布的东西（`AppServices.present`）只经这里写，规则见 `AppServices.startSnapshots`。
final class SnapshotPublisher {
    private let store: CueStore
    private let directory: URL
    private let present: @MainActor (_ digest: CueDigest, _ first: Bool, _ resend: Bool) async throws -> CueNow
    private var published: WidgetSnapshots?
    private var ticket = 0
    private var turn: Task<Bool, any Error>?

    init(store: CueStore, directory: URL, present: @escaping @MainActor (_ digest: CueDigest, _ first: Bool, _ resend: Bool) async throws -> CueNow) {
        self.store = store
        self.directory = directory
        self.present = present
    }

    /// 也是观察的落点：进入后台前（`resend`：岛按此刻重发一次，过时时刻从这时算）、推送叫醒拉完之后（回调一返回系统就可能挂起 App，`IOSAppDelegate`）也直接调，不等那条异步的观察。
    ///
    /// 读库、发布活动与角标、落盘是一个单元，按到达先后串行（活动与角标会让出主线程）。读在轮到自己时才做：
    /// 每个单元读到的都不比前一个单元更旧，最后一个单元写下的就是最新一次读取，旧读取不会晚于新读取写回。
    /// 后面还排着更新的请求时，前面的（不要重发的）直接跳过，由最后那个读最新的；要重发的不跳。
    /// 被跳过的也等到队尾那一份做完才返回：调用方（后台推送叫醒后的收尾、回到前台）返回时快照已按最新落盘，之后系统挂起 App 也不缺。
    func writeSnapshots(resend: Bool = false) async throws {
        ticket += 1
        let ticket = ticket
        let previous = turn
        let turn = Task {
            _ = await previous?.result  // 前一份的失败由它的调用方报告
            guard resend || ticket == self.ticket else { return false }
            let read = try await CueReading.Read.read(from: store, widget: true)
            try await render(read.widget!, read.digest, resend: resend)
            return true
        }
        self.turn = turn
        guard try await turn.value else { return await latestSnapshot(after: turn) }
    }

    /// 被顶掉的请求等队尾：等的时候又来了新的就接着等新的队尾。队尾的失败由它自己的调用方报告。
    private func latestSnapshot(after skipped: Task<Bool, any Error>) async {
        var awaited = skipped
        while let latest = turn, latest != awaited {
            awaited = latest
            _ = await latest.result
        }
    }

    private func render(_ content: WidgetContent, _ digest: CueDigest, resend: Bool) async throws {
        let now = try await present(digest, published == nil, resend)
        try publish(WidgetSnapshots(content, now: now))
    }

    private func publish(_ snapshots: WidgetSnapshots) throws {
        let old = published
        try write(snapshots.projects, over: old?.projects)
        let shown = [try write(snapshots.home, over: old?.home), try write(snapshots.cue, over: old?.cue, same: { $0.same(as: $1) })]
        #if os(iOS)
        if shown.contains(true) { WidgetCenter.shared.reloadAllTimelines() }
        #endif
        published = snapshots
    }

    @discardableResult
    private func write<S: SnapshotFile & Equatable>(_ snapshot: S, over old: S?, same: (S, S) -> Bool = (==)) throws -> Bool {
        if let old, same(snapshot, old) { return false }
        try Snapshots.write(snapshot, to: directory)
        return true
    }
}
