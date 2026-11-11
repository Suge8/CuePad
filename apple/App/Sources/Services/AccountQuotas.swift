import CueStore
import Foundation
import Observation
#if os(macOS)
import CueBridge
#endif

/// 账号额度的唯一界面订阅，与额度刷新唯一的一份状态（`phase`）。
/// 同一批来源正在查就并进那一次；来源换了，等这一次查完再取最新来源快照，标识与查询使用同一批来源。自动触发在同一批来源没查到后 `cooldown` 内不再问，手动不受限。
/// 界面离开不取消已启动的共享查询，由查询自己记下终态；尚未启动的自动查询随页面取消。
/// 结果来自所等那一次的终态（Mac 直接问会话里的扩展；手机等投送请求写回，只有写回成功算查到），这里不另设时限。
/// 手机上传未获确认时重读请求：已有结果照用，有服务器锚点照原期限等；仍无锚点就结束本次刷新，原请求留给同步重试、下次查询复用。
/// 不设周期刷新；已有观测的新鲜程度不能证明清单没变化，所以每次触发都问。`items` 的先后只在这里定（`QuotaMeter.ordered`），各处照这个顺序摆。
/// 网关原观测时间只由 readAt 决定，读取清单不会刷新 Claude 的 /usage。
@Observable
final class AccountQuotas {
    enum Trigger { case automatic, manual }

    typealias Query = @MainActor () async -> ShownText?

    struct Batch {
        let key: [String]
        let query: Query
    }

    enum Phase: Equatable {
        case idle
        /// 在查；上一次没查到时带着那次的原因（明细里那一行留着，只把重试换成在查，不闪掉再出现）
        case running(key: [String], task: Task<ShownText?, Never>, after: ShownText?)
        case failed(ShownText, key: [String], at: Date)
    }

    static let cooldown: TimeInterval = 60

    private(set) var items: [AccountQuota] = []
    private(set) var phase: Phase = .idle

    func follow(_ store: CueStore, changed: ([AccountQuota]) async -> Void) async throws {
        for try await items in store.observe({ QuotaMeter.ordered(try $0.accountQuotas()) }) where items != self.items {
            self.items = items
            await changed(items)
        }
    }

    /// 等待期间来源可以变化；每次获得空闲状态后重新取快照，不替取消的页面启动下一轮。
    @discardableResult
    func refresh(_ trigger: Trigger, batch: () -> Batch) async -> ShownText? {
        while true {
            if trigger == .automatic && Task.isCancelled { return nil }
            let batch = batch()
            if trigger == .automatic && batch.key.isEmpty { return nil }
            if case .running(let key, let task, _) = phase {
                if key == batch.key { return await task.value }
                _ = await task.value
                continue
            }
            var previous: ShownText?
            if case .failed(let reason, let key, let at) = phase {
                if trigger == .automatic && key == batch.key && Date.now.timeIntervalSince(at) < Self.cooldown { return nil }
                previous = reason
            }
            // 任务返回前提交终态，任何等待者恢复时都不可能再等一个已完成但尚未清掉的任务。
            let task = Task {
                let failure = await batch.query()
                phase = failure.map { .failed($0, key: batch.key, at: .now) } ?? .idle
                return failure
            }
            phase = .running(key: batch.key, task: task, after: previous)
            return await task.value
        }
    }
}

extension AppServices {
    /// 读失败时报告并停止。
    func startAccountQuotas() {
        follow(reporting: { .syncUnavailable(String(localized: "读取额度失败，额度不再更新：\(String(describing: $0))")) }) {
            try await self.accountQuotas.follow(self.store) { await self.alerts?.remind($0) }
        }
    }

    /// 刷新额度的唯一入口。
    @discardableResult
    func refreshQuota(_ trigger: AccountQuotas.Trigger) async -> ShownText? {
        await accountQuotas.refresh(trigger) { quotaBatch }
    }

    var quotaRefreshKey: [String] { quotaBatch.key }

    #if os(macOS)
    /// 换版本期间发不进命令，所以不算。
    /// 不同会话可能有独立的模型目录与授权；不根据当前模型推断其他会话的来源已覆盖。
    private var quotaSessions: [Bridge.Slot] { bridge.slots.filter { $0.session.capabilities.contains(.quota) && !$0.session.upgrading } }

    private var quotaBatch: AccountQuotas.Batch {
        let sessions = quotaSessions
        let key = sessions.map { slot in
            let models = slot.session.availableModels + [slot.session.model].compactMap { $0 }
            return "\(slot.id)/\(models.map { "\($0.key.provider)/\($0.account?.source ?? $0.account?.scope ?? "")" }.sorted().joined(separator: "/"))"
        }.sorted()
        return AccountQuotas.Batch(key: key) { await self.queryQuota(in: sessions) }
    }

    /// 经能答额度的会话里的扩展查（它有 Pi 的令牌与自动刷新，App 不碰 Pi 的登录文件）；返回第一个没查到的会话报的原因。
    private func queryQuota(in sessions: [Bridge.Slot]) async -> ShownText? {
        guard !sessions.isEmpty else { return ShownText("这台 Mac 上没有在线的 Pi 会话") }
        return await withTaskGroup(of: ShownText?.self) { group in
            for session in sessions {
                group.addTask { [bridge, id = session.id] in
                    do { try await bridge.refreshQuota(in: id); return nil }
                    catch { return ShownText(error) }
                }
            }
            var failure: ShownText?
            for await result in group { failure = failure ?? result }
            return failure
        }
    }
    #else
    private var quotaBatch: AccountQuotas.Batch {
        let hosts = Array(Set(liveSessions.live.filter { $0.state.capabilities.contains(.quota) }.map(\.state.hostID))).sorted()
        return AccountQuotas.Batch(key: hosts) { await self.queryQuota(on: hosts) }
    }

    /// 单台没查到不挡别的；写回的观测经原同步路径到达。返回第一台没查到的原因。
    private func queryQuota(on hosts: [String]) async -> ShownText? {
        guard !hosts.isEmpty else { return ShownText("没有连着 Pi 会话的 Mac") }
        return await withTaskGroup(of: ShownText?.self) { group in
            for host in hosts {
                group.addTask { [self] in
                    do {
                        var request = try await store.requestQuotaRefresh(on: host)
                        if await sync?.upload(request.id) != true {
                            guard let latest = try await store.latest(of: request) else { throw CueStoreError.notFound }
                            request = latest
                            if request.isOpen && request.serverAt == nil { return ShownText("请求尚未确认上传，联网后可重试") }
                        }
                        // 只有写回成功才算查到：没能送达、到期未确认、本版本不认识的状态都是没查到
                        let done = if request.isOpen { try await store.outcome(of: request) } else { request }
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
