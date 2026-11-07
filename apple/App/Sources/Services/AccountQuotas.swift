import CueStore
import Foundation
import Observation
#if os(macOS)
import CuePi
#endif

/// 账号额度的唯一界面订阅，与额度刷新唯一的一份状态（`phase`）：空闲 → 在查 → 查到回空闲，没查到记下原因与时刻（`failed`）。
/// 触发只有两种（`Trigger`）：自动——额度出现在前台的页上、可问的来源变了、打开明细、Mac 菜单栏面板弹出（`refreshesQuota`）；
/// 手动——明细里没查到那一行的"重试"（`QuotaRefreshNote`），与 Mac 执行手机发来的刷新请求（投送方式 `quota`）。
/// 同一批来源正在查就并进那一次；来源换了，等这一次查完再查新的。自动触发在同一批来源没查到后 `cooldown` 内不再问，手动不受限。
/// 没有可问的来源（`quotaRefreshKey` 为空：Mac 上没有能答额度的会话，手机上没有连着这种会话的 Mac，见 `AgentCapabilities.quota`）时自动触发什么也不做。
/// 没查到不弹提示：原因只在明细里写，旁边给重试；账号自己的读数照旧是上次的值与更新时间。界面离开、等它的任务被取消也不影响这一次：结果照样记进 `phase`。
/// 结果只来自所等那一次的终态（Mac 直接问会话里的扩展；手机等投送请求写回，`CueStore.outcome(of:)`，只有写回成功算查到），这里不另设时限。
/// 不设周期刷新；已有观测的新鲜程度不能证明清单没变化，所以每次触发都问。`items` 的先后只在这里定（`QuotaMeter.ordered`），各处照这个顺序摆。
/// 网关原观测时间只由 readAt 决定，读取清单不会刷新 Claude 的 /usage。
@Observable
final class AccountQuotas {
    enum Trigger { case automatic, manual }

    /// 查一次：返回没查到的原因，查到为 nil。
    typealias Query = @MainActor () async -> ShownText?

    enum Phase: Equatable {
        case idle
        /// 在查；上一次没查到时带着那次的原因（明细里那一行留着，只把重试换成在查，不闪掉再出现）
        case running(after: ShownText?)
        /// 对 `key` 那批来源没查到：`reason` 是原因（可能是那台 Mac 写回的），`at` 是查完的时刻
        case failed(ShownText, key: [String], at: Date)
    }

    /// 没查到之后多久内自动触发不再问同一批来源。
    static let cooldown: TimeInterval = 60

    private(set) var items: [AccountQuota] = []
    private(set) var phase: Phase = .idle
    @ObservationIgnored private var running: (key: [String], task: Task<ShownText?, Never>)?

    func follow(_ store: CueStore, changed: ([AccountQuota]) async -> Void) async throws {
        for try await items in store.observe({ QuotaMeter.ordered(try $0.accountQuotas()) }) where items != self.items {
            self.items = items
            await changed(items)
        }
    }

    /// 对 `key` 那批来源查一次（`query` 返回没查到的原因，查到为 nil）；返回这一次（或并进去的那一次）没查到的原因，被冷却挡下、没有可问的为 nil。
    @discardableResult
    func refresh(_ trigger: Trigger, key: [String], query: @escaping Query) async -> ShownText? {
        if let running {
            if running.key == key { return await running.task.value }
            _ = await running.task.value
            return await refresh(trigger, key: key, query: query)
        }
        if trigger == .automatic {
            guard !key.isEmpty else { return nil }
            if case .failed(_, key, let at) = phase, Date.now.timeIntervalSince(at) < Self.cooldown { return nil }
        }
        let task = Task { await query() }
        running = (key, task)
        if case .failed(let reason, _, _) = phase { phase = .running(after: reason) } else { phase = .running(after: nil) }
        let failure = await task.value
        running = nil
        phase = failure.map { .failed($0, key: key, at: .now) } ?? .idle
        return failure
    }
}

extension AppServices {
    /// 开始跟随额度记录（`start()` 调用）；读失败时报告并停止。
    func startAccountQuotas() {
        follow(reporting: { .syncUnavailable(String(localized: "读取额度失败，额度不再更新：\(String(describing: $0))")) }) {
            try await self.accountQuotas.follow(self.store) { await self.alerts?.remind($0) }
        }
    }

    /// 刷新额度的唯一入口（规则见 `AccountQuotas`）；返回没查到的原因。
    @discardableResult
    func refreshQuota(_ trigger: AccountQuotas.Trigger) async -> ShownText? {
        await accountQuotas.refresh(trigger, key: quotaRefreshKey, query: queryQuota)
    }

    #if os(macOS)
    /// 能答额度的会话：在线、带 `AgentCapabilities.quota`、扩展不在换新版本（换版本期间发不进命令）。
    /// 不同会话可能有独立的模型目录与授权；不根据当前模型推断其他会话的来源已覆盖。
    private var quotaSessions: [PiBridge.Slot] { pi.slots.filter { $0.session.capabilities.contains(.quota) && !$0.session.upgrading } }

    /// 可问的来源：每个能答额度的会话与它能用的授权（会话连上、换了模型目录时变，额度视图据此再看一次）。
    var quotaRefreshKey: [String] {
        quotaSessions.map { slot in
            let models = slot.session.availableModels + [slot.session.model].compactMap { $0 }
            return "\(slot.id)/\(models.map { "\($0.key.provider)/\($0.account?.source ?? $0.account?.scope ?? "")" }.sorted().joined(separator: "/"))"
        }.sorted()
    }

    /// 经能答额度的会话里的扩展查（它有 Pi 的令牌与自动刷新，App 不碰 Pi 的登录文件），查到的随桥的 `.quota` 写进库；
    /// 返回第一个没查到的会话报的原因。
    private func queryQuota() async -> ShownText? {
        let sessions = quotaSessions
        guard !sessions.isEmpty else { return ShownText("这台 Mac 上没有在线的 Pi 会话") }
        return await withTaskGroup(of: ShownText?.self) { group in
            for session in sessions {
                group.addTask { [pi, id = session.id] in
                    do { try await pi.refreshQuota(in: id); return nil }
                    catch { return ShownText(error) }
                }
            }
            var failure: ShownText?
            for await result in group { failure = failure ?? result }
            return failure
        }
    }
    #else
    /// 可问的来源：连着能答额度的会话的 Mac（`AgentCapabilities.quota`）。
    var quotaRefreshKey: [String] {
        Array(Set(liveSessions.live.filter { $0.state.capabilities.contains(.quota) }.map(\.state.hostID))).sorted()
    }

    /// 请每台可问的 Mac 经已有投送通路查一次，单台没查到不挡别的；写回的观测经原同步路径到达。返回第一台没查到的原因。
    private func queryQuota() async -> ShownText? {
        let hosts = quotaRefreshKey
        guard !hosts.isEmpty else { return ShownText("没有连着 Pi 会话的 Mac") }
        return await withTaskGroup(of: ShownText?.self) { group in
            for host in hosts {
                group.addTask { [self] in
                    do {
                        let request = try await store.requestQuotaRefresh(on: host)
                        await upload(request.id)
                        // 只有写回成功才算查到：没能送达、到期未确认、本版本不认识的状态都是没查到
                        let done = try await store.outcome(of: request)
                        guard done.status != .known(.succeeded) else { return nil }
                        return done.failure.map(ShownText.verbatim) ?? done.reason ?? ShownText("那台 Mac 没有写回结果")
                    } catch { return ShownText(error) }
                }
            }
            var failure: ShownText?
            for await result in group { failure = failure ?? result }
            return failure
        }
    }
    #endif
}
