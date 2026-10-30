import CueStore
import Foundation
import Observation
#if os(macOS)
import CuePi
#endif

/// 账号额度的唯一界面订阅。打开面板、回前台或连接来源变化时读取账号清单；已有观测的新鲜程度不能证明清单没变化。
/// 同时来的请求合并；不设周期刷新。网关原观测时间只由 readAt 决定，读取清单不会刷新 Claude 的 /usage。
@Observable
final class AccountQuotas {
    private(set) var items: [AccountQuota] = []
    @ObservationIgnored private var running: (key: [String], task: Task<Void, any Error>)?

    func follow(_ store: CueStore, changed: ([AccountQuota]) async -> Void) async throws {
        for try await items in store.observe({ try $0.accountQuotas() }) where items != self.items {
            self.items = items
            await changed(items)
        }
    }

    /// 读取清单（Mac 经在线扩展，手机请各来源的 Mac 查）；正在查就等那一次。
    /// 没有新报告不算新观测；时效只读记录，不另存"已刷新"标志。
    func refresh(key: [String], using refresh: @escaping @MainActor () async throws -> Void) async throws {
        if let running {
            if running.key == key { return try await running.task.value }
            _ = await running.task.result
            return try await self.refresh(key: key, using: refresh)
        }
        let task = Task {
            defer { self.running = nil }
            try await refresh()
        }
        running = (key, task)
        try await task.value
    }
}

extension AppServices {
    /// 开始跟随额度记录（`start()` 调用）；读失败时报告并停止。
    func startAccountQuotas() {
        follow(reporting: { .syncUnavailable(String(localized: "读取额度失败，额度不再更新：\(String(describing: $0))")) }) {
            try await self.accountQuotas.follow(self.store) { await self.alerts?.remind($0) }
        }
    }

    #if os(macOS)
    /// 此刻有没有可问的：在线的会话（额度视图据此在会话连上时再看一次）。
    var canRefreshQuota: Bool { !quotaSessions.isEmpty }

    /// 不同会话可能有独立的模型目录与授权；不根据当前模型推断其他会话的来源已覆盖。
    private var quotaSessions: [PiBridge.Slot] { pi.slots.filter { !$0.session.upgrading && $0.session.agent == .pi } }

    var quotaRefreshKey: [String] {
        quotaSessions.map { slot in
            let models = slot.session.availableModels + [slot.session.model].compactMap { $0 }
            return "\(slot.id)/\(models.map { "\($0.key.provider)/\($0.account?.source ?? $0.account?.scope ?? "")" }.sorted().joined(separator: "/"))"
        }.sorted()
    }

    /// 手机发来的刷新请求（投送方式 `quota`）：与本机视图合并同时来的查询，失败照常写回原因。
    func refreshQuotaForRequest() async throws {
        guard canRefreshQuota else { throw SendError.noLiveSession }
        try await accountQuotas.refresh(key: quotaRefreshKey, using: refreshQuota)
    }

    /// 经在线会话里的扩展查（它有 Pi 的令牌与自动刷新，App 不碰 Pi 的登录文件），查到的随桥的 `.quota` 写进库。
    fileprivate func refreshQuota() async throws {
        let sessions = quotaSessions
        guard !sessions.isEmpty else { throw SendError.noLiveSession }
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for session in sessions {
                let id = session.id
                group.addTask { [pi] in
                    do { try await pi.refreshQuota(in: id); return true }
                    catch { return false }
                }
            }
            var succeeded = true
            for await result in group { succeeded = result && succeeded }
            return succeeded
        }
        if !succeeded { throw SendError.quotaUnavailable }
    }
    #else
    /// 此刻有没有可问的：知道哪台 Mac（写过额度的，或有在线会话的）。
    var canRefreshQuota: Bool { !quotaHosts.isEmpty }

    private var quotaHosts: [String] {
        Array(Set(accountQuotas.items.map(\.hostID) + liveSessions.live.map { $0.state.hostID })).sorted()
    }

    var quotaRefreshKey: [String] { quotaHosts }

    /// 每台来源 Mac 都走已有投送通路，单台失败不阻止其他来源。写回的观测经原同步路径到达。
    fileprivate func refreshQuota() async throws {
        let hosts = quotaHosts
        let succeeded = await withTaskGroup(of: Bool.self) { group in
            for host in hosts {
                group.addTask { [self] in
                    do {
                        let request = try await store.requestQuotaRefresh(on: host)
                        await upload(request.id)
                        return try await store.outcome(of: request).failure == nil
                    } catch { return false }
                }
            }
            var succeeded = true
            for await result in group { succeeded = result && succeeded }
            return succeeded
        }
        if !succeeded { throw SendError.quotaUnavailable }
    }
    #endif
}

extension Workspace {
    func refreshQuota() async {
        do { try await services.accountQuotas.refresh(key: services.quotaRefreshKey, using: services.refreshQuota) }
        catch { fail(error) }
    }
}
