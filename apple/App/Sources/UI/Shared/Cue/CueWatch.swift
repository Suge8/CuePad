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
    @ObservationIgnored private var deadline: Task<Void, Never>?
    #if os(macOS)
    /// 这台 Mac 的管理器与标识：Cue 住在这台时状态以管理器为准。
    @ObservationIgnored private var host: (service: CueService, id: String)?
    #endif

    var presence: CuePresence {
        #if os(macOS)
        if let host, digest.hostID == host.id, digest.enabled { return CuePresence(host.service.state) }
        #endif
        return CuePresence.derive(digest, overdue: overdue)
    }
    var name: String { digest.name }

    func mood(composing: Bool = false) -> CueMood {
        CueMood.of(presence, waiting: digest.waiting, composing: composing, justDone: digest.lastSaidDone)
    }

    #if os(macOS)
    func attach(_ service: CueService, hostID: String) { host = (service, hostID) }
    #endif

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

extension AppSettings {
    private static let cueSeenKey = "cueSeenAt"

    /// 上次离开 Cue 页的时刻（本机）："你不在时"那张卡从它之后的变化算。
    var cueSeenAt: Date? {
        get { defaults.object(forKey: Self.cueSeenKey) as? Date }
        set { defaults.set(newValue, forKey: Self.cueSeenKey) }
    }
}
