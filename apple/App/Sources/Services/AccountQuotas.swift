import CueStore
import Foundation
import Observation
#if os(macOS)
import CuePi
#endif

/// 订阅账号的额度（`AccountQuota`，每个提供方一条），整个 App 一份：Agent 页顶部、菜单栏面板、回复框的模型胶囊与模型菜单都读这里，
/// 不各自订阅。数据只在 Mac 上由桥写入（回复里带回的观测随时到，见 `AppServices.consumePiChanges`）；这里还管主动刷新的节流：
/// 只在额度视图出现、有观测陈旧（`AccountQuota.staleAfter`）时查一次，同时来的几次合并成一次，查到后同样久之内不再查，
/// 失败后冷却 `failureCooldown`。没有定时器：不看就不查。
@Observable
final class AccountQuotas {
    private(set) var items: [AccountQuota] = []
    @ObservationIgnored private var running: Task<Bool, any Error>?
    @ObservationIgnored private var nextAllowed = Date.distantPast

    private static let failureCooldown: TimeInterval = 2 * 60

    func follow(_ store: CueStore) async throws {
        for try await items in store.observe({ try $0.accountQuotas() }) where items != self.items { self.items = items }
    }

    /// 还一条都没有，或有一条陈旧了。
    private func needsRefresh(at now: Date) -> Bool { items.isEmpty || items.contains { $0.isStale(at: now) } }

    /// 需要时用 `refresh` 查一次（Mac 经在线会话里的扩展，手机请 Mac 查）；正在查就等那一次。
    /// `refresh` 返回 false 是此刻没有可问的（没有在线会话、不知道哪台 Mac）：不算查过，有了可问的再来（见 `refreshesQuota`）。
    func refreshIfStale(using refresh: @escaping @MainActor () async throws -> Bool) async throws {
        if let running {
            _ = try await running.value
            return
        }
        let now = Date.now
        guard now >= nextAllowed, needsRefresh(at: now) else { return }
        let task = Task { try await refresh() }
        running = task
        defer { running = nil }
        do {
            if try await task.value { nextAllowed = now.addingTimeInterval(AccountQuota.staleAfter) }
        } catch {
            nextAllowed = now.addingTimeInterval(Self.failureCooldown)
            throw error
        }
    }
}

extension AppServices {
    /// 开始跟随额度记录（`start()` 调用）；读失败时报告并停止。
    func startAccountQuotas() {
        follow(reporting: { .syncUnavailable("读取订阅额度失败，额度不再更新：\($0)") }) {
            try await self.accountQuotas.follow(self.store)
        }
    }

    /// 额度视图出现时调用：陈旧就查一次。查不到（断网、VPN 断了、没有在线会话）不提示——界面照旧显示上次的值与"更新于几分钟前"。
    func refreshQuotaIfStale() async {
        do {
            try await accountQuotas.refreshIfStale(using: refreshQuota)
        } catch {
            Self.log.notice("订阅额度没能刷新：\(error.localizedDescription, privacy: .public)")
        }
    }

    #if os(macOS)
    /// 此刻有没有可问的：在线的会话（额度视图据此在会话连上时再看一次）。
    var canRefreshQuota: Bool { quotaSession != nil }

    /// 能问的会话：协议对得上的在线会话（与 `canRefreshQuota` 同一个判定，视图不会在问不了时一出现就走一次刷新）。
    private var quotaSession: PiBridge.Slot? { pi.slots.first { $0.session.state != .incompatible } }

    /// 手机发来的刷新请求（投送方式 `quota`）：与本机视图同一套节流，失败照常写回原因（手机不提示）。
    func refreshQuotaForRequest() async throws {
        guard canRefreshQuota else { throw SendError.noLiveSession }
        try await accountQuotas.refreshIfStale(using: refreshQuota)
    }

    /// 经在线会话里的扩展查（它有 Pi 的令牌与自动刷新，App 不碰 Pi 的登录文件），查到的随桥的 `.quota` 写进库。
    private func refreshQuota() async throws -> Bool {
        guard let session = quotaSession else { return false }
        try await pi.refreshQuota(in: session.id)
        return true
    }
    #else
    /// 此刻有没有可问的：知道哪台 Mac（写过额度的，或有在线会话的）。
    var canRefreshQuota: Bool { quotaHost != nil }

    private var quotaHost: String? {
        accountQuotas.items.max { $0.modifiedAt < $1.modifiedAt }?.hostID ?? liveSessions.live.first?.state.hostID
    }

    /// 请最近写过额度的那台 Mac 查（还没有额度记录时，请有在线会话的 Mac），写出后立即上传、不等结果：新值随同步回来。
    private func refreshQuota() async throws -> Bool {
        guard let host = quotaHost else { return false }
        let request = try await store.requestQuotaRefresh(on: host)
        Task { await upload(request.id) }
        return true
    }
    #endif
}
