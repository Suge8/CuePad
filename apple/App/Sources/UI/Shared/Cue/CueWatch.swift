import CueStore
import CueSync
import Foundation
import Observation

/// 一个窗口里 Cue 的现状（`CueDigest` 与 `CuePresence`）和 Cue 页的输入草稿：侧栏、底栏、菜单栏面板与 Cue 页都读这一份，不各自订阅。
/// 你最近一句等回执满 `Speech.receiptLimit` 才可能算它在睡觉：等是业务语义，到点由一个睡眠任务刷新 `now`，不轮询。
@Observable
final class CueWatch {
    private(set) var digest = CueDigest.empty
    /// 推 Cue 在不在用的"此刻"：你最近一句变了、或它等回执到点时刷新。
    private(set) var now = Date.now
    /// 到 Cue 住的那台 Mac 要经过的同步（`AppServices.relay`，`Workspace.observeCue` 接上）。
    @ObservationIgnored var relay: (String?) -> SyncStatus? = { _ in nil }
    /// Cue 页的输入（离开再回来还在）。
    var draft = ComposerDraft()
    /// "Cue 记得什么"开着。
    var showsMemory = false
    #if os(macOS)
    /// Cue 页右侧开着"运行情况"（`CueRunPanel`）。
    var showsRun = false
    #endif
    @ObservationIgnored private var deadline: Task<Void, Never>?

    var presence: CuePresence { CuePresence.derive(digest, now: now, relay: relay(digest.hostID)) }
    var name: String { digest.name }
    /// 能对它说话：启用了（住的那台 Mac 不在线也能说，开机后它会读到）。
    var canHear: Bool { presence != .disabled }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: digest.waiting.count, composing: composing, justDone: digest.lastSaidDone)
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
        now = .now
        guard let pending, let due = Speech.deadline(said: pending.at, delivered: pending.deliveredAt) else { return }
        let left = due.timeIntervalSince(now)
        guard left > 0 else { return }
        deadline = Task { [weak self] in
            guard (try? await Task.sleep(for: .seconds(left))) != nil else { return }
            self?.now = .now
        }
    }
}
