import CueStore
import Foundation
import Observation
#if os(macOS)
import CuePi
#endif

/// 授权分区的额度能力与观测（`AccountQuota`），整个 App 一份：Mac 侧栏与手机进展页顶栏的额度环、菜单栏面板、回复框的模型胶囊与模型菜单都读这里，
/// 不各自订阅；每次变化按它重排周额度提醒（`QuotaReminder`）。数据只在 Mac 上由桥写入（回复里带回的观测随时到，见 `AppServices.consumePiChanges`）；这里还管主动刷新的节流：
/// 只在额度视图出现、有观测陈旧（`AccountQuota.staleAfter`）时查一次，同时来的几次合并成一次，查到后同样久之内不再查，
/// 失败冷却取自记录的 `AccountQuota.failureCooldown`。没有定时器：不看就不查。
@Observable
final class AccountQuotas {
    private(set) var items: [AccountQuota] = []
    @ObservationIgnored private var running: Task<Void, any Error>?

    func follow(_ store: CueStore, changed: ([AccountQuota]) async -> Void) async throws {
        for try await items in store.observe({ try $0.accountQuotas() }) where items != self.items {
            self.items = items
            await changed(items)
        }
    }

    private func needsRefresh(at now: Date) -> Bool { items.isEmpty || items.contains { $0.isStale(at: now) } }

    /// 需要时用 `refresh` 查一次（Mac 经在线会话里的扩展，手机请 Mac 查）；正在查就等那一次。
    /// 没有新报告不算新观测；时效只读记录，不另存"已刷新"标志。
    func refreshIfStale(using refresh: @escaping @MainActor () async throws -> Void) async throws {
        if let running {
            try await running.value
            return
        }
        let now = Date.now
        if items.contains(where: { $0.status == .failed && !$0.isStale(at: now) }) { throw SendError.quotaUnavailable }
        guard needsRefresh(at: now) else { return }
        let task = Task { try await refresh() }
        running = task
        defer { running = nil }
        try await task.value
    }
}

extension AppServices {
    /// 开始跟随额度记录（`start()` 调用）；读失败时报告并停止。
    func startAccountQuotas() {
        follow(reporting: { .syncUnavailable(String(localized: "读取订阅额度失败，额度不再更新：\(String(describing: $0))")) }) {
            try await self.accountQuotas.follow(self.store) { await self.alerts?.remind($0) }
        }
    }

    #if os(macOS)
    /// 此刻有没有可问的：在线的会话（额度视图据此在会话连上时再看一次）。
    var canRefreshQuota: Bool { quotaSession != nil }

    /// 能问的会话：协议对得上的在线会话（与 `canRefreshQuota` 同一个判定，视图不会在问不了时一出现就走一次刷新）。
    private var quotaSession: PiBridge.Slot? { pi.slots.first { !$0.session.upgrading } }

    /// 手机发来的刷新请求（投送方式 `quota`）：与本机视图同一套节流，失败照常写回原因。
    func refreshQuotaForRequest() async throws {
        guard canRefreshQuota else { throw SendError.noLiveSession }
        try await accountQuotas.refreshIfStale(using: refreshQuota)
    }

    /// 经在线会话里的扩展查（它有 Pi 的令牌与自动刷新，App 不碰 Pi 的登录文件），查到的随桥的 `.quota` 写进库。
    fileprivate func refreshQuota() async throws {
        guard let session = quotaSession else { return }
        try await pi.refreshQuota(in: session.id)
    }
    #else
    /// 此刻有没有可问的：知道哪台 Mac（写过额度的，或有在线会话的）。
    var canRefreshQuota: Bool { quotaHost != nil }

    private var quotaHost: String? {
        accountQuotas.items.max { $0.modifiedAt < $1.modifiedAt }?.hostID ?? liveSessions.live.first?.state.hostID
    }

    /// 请最近写过额度的那台 Mac 查（还没有额度记录时，请有在线会话的 Mac），写出后立即上传、等待投送结果；能力与新观测随同步回来。
    fileprivate func refreshQuota() async throws {
        guard let host = quotaHost else { return }
        let request = try await store.requestQuotaRefresh(on: host)
        await upload(request.id)
        if let failure = try await store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
    }
    #endif
}

extension Workspace {
    func refreshQuota() async {
        do { try await services.accountQuotas.refreshIfStale(using: services.refreshQuota) }
        catch { fail(error) }
    }
}
