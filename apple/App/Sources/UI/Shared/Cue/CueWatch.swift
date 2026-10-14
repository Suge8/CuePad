import CueStore
import Foundation
import Observation

/// 一个窗口里 Cue 的现状（`CueDigest` 与 `CuePresence`）和 Cue 页的输入草稿：侧栏、底栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
/// 你的话交不出去要等满 `CuePresence.undeliveredGrace` 才算它没在：等是业务语义，到点由一个睡眠任务改 `overdue`，不轮询。
@Observable
final class CueWatch {
    private(set) var digest = CueDigest.empty
    /// 你最近一句等了超过宽限还没交出去。
    private(set) var overdue = false
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif
    @ObservationIgnored private var deadline: Task<Void, Never>?

    var presence: CuePresence { CuePresence.derive(digest, overdue: overdue) }
    var name: String { digest.name }
    /// 能对它说话：启用了（住的那台 Mac 不在线也能说，开机后它会读到）。
    var canHear: Bool { presence != .disabled }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: digest.waiting, composing: composing, justDone: digest.lastSaidDone)
    }

    /// 跟随资料库直到任务取消。
    func follow(_ store: CueStore) async throws {
        defer { deadline?.cancel() }
        for try await next in store.observe({ try CueDigest.read(from: $0) }) where next != digest {
            digest = next
            watch(next.pendingYou)
        }
    }

    private func watch(_ pending: CueDigest.Pending?) {
        deadline?.cancel()
        guard let pending, !pending.delivered else { return overdue = false }
        let left = pending.at.addingTimeInterval(CuePresence.undeliveredGrace).timeIntervalSinceNow
        overdue = left <= 0
        guard left > 0 else { return }
        deadline = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(left))) != nil else { return }
            self?.overdue = true
        }
    }
}
