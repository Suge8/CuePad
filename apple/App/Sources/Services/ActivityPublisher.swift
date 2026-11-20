#if os(macOS)
import CueStore
import CueSync
import Foundation
import Observation
import OSLog

/// 手机上的岛由 Mac 唯一发布内容，手机只登记地址；中转不存业务状态。
/// 同一秒内只发最新一份（APNs timestamp 是秒）；网络慢或失败时不排历史队列。
/// 可作答的提问先确认 iCloud 收下；每次等待后从库核对当前内容，不把已撤回或回答的旧提问补推回去。
/// 成功只表示 APNs 收下，不表示已上屏。一眼看得出的变化（`CueNow.glance`、等你）用高优先级，其余用低的，免得高频推送耗尽系统预算。
/// 读库、推送出错都只记日志、按退避再来，跟着 App 一直跑到取消：Mac 上没有别处能告诉你，停下就再也不推了。
///
/// 岛的一生也在这里定（手机只有 App 在前台才开得了）：
/// - 没活了、刚完的也过了 `CueNow.lingersUntil` 就结束；快到系统的八小时上限（`ActivityDestination.retireAt`）结束并清掉，不立刻续开：到点多在半夜。
/// - 手机上没有岛、又有比它没的那一刻更晚开工或开始等你的事（`CueNow.newest`），远程开一只（push-to-start）。
///   所以你划掉的、到上限收掉的，同一件事不再开；这台刚启动时还在跑的也不开。两次之间至少隔 `startSpacing`：系统对远程开岛另有额度，用完就静默不开。
/// - 远程开的那只要等手机被唤醒、登记了地址才推得动；没等到（App 被强杀、额度用完）就留给手机下次到前台自己开。
final class ActivityPublisher {
    private let endpoint: URL
    private let session: URLSession
    private var sent: [String: Sent] = [:]
    private var islands: [String: Island] = [:]
    private var lastAttempt = Date.distantPast
    private var lingersUntil: Date?
    private let launched = Date.now
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "live-activity")
    private static let requestLimit: TimeInterval = 15
    private static let cadence: TimeInterval = 1
    private static let startSpacing: TimeInterval = 10 * 60
    private static let startLifetime: TimeInterval = 5 * 60

    private struct Sent {
        var destination: ActivityDestination
        var state: CueActivityState
    }

    /// 这台对一台手机上的岛所知道的：没了的时刻（没见过就从这台启动算）、由这台结束的那只（手机还没来得及删地址）、上次远程开的时刻。
    private struct Island {
        var gone: Date
        var ended: String?
        var started: Date?
    }

    init(host: String, configuration: URLSessionConfiguration = .ephemeral) {
        endpoint = URL(string: "https://\(host)/v1/activity")!
        configuration.timeoutIntervalForRequest = Self.requestLimit
        configuration.timeoutIntervalForResource = Self.requestLimit
        session = URLSession(configuration: configuration)
    }

    func run(_ services: AppServices) async {
        defer { session.invalidateAndCancel() }
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = CueReading(store: services.store, widget: false)
        let timing = services.timing
        let reading: @isolated(any) @Sendable () async throws -> Void = {
            var retry = Backoff(first: .seconds(1), cap: Backoff.waitingCap)
            while true {
                do {
                    for try await _ in source.updates() {
                        retry.reset()
                        changed.yield()
                    }
                    return changed.finish()
                } catch where !Task.isCancelled {
                    Self.log.error("实时活动读不出库里的 Cue，退避后重读：\(String(describing: error), privacy: .public)")
                    try await timing.sleep(retry.next())
                }
            }
        }
        let availability: @MainActor @Sendable () async throws -> Void = {
            for await _ in Observations({ (services.knowsActivityState, services.speech) }) { changed.yield() }
        }
        let publishing: @MainActor @Sendable () async throws -> Void = {
            try await self.publish(changes, retrying: changed, services: services)
        }
        // 子任务只因取消抛出
        try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: reading)
            group.addTask(operation: publishing)
            group.addTask(operation: availability)
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func publish(_ changes: AsyncStream<Void>, retrying changed: AsyncStream<Void>.Continuation, services: AppServices) async throws {
        var retry = Backoff(first: .seconds(1), cap: Backoff.waitingCap)
        var failed = false
        var lingering: Task<Void, Never>?
        defer { lingering?.cancel() }
        for await _ in changes {
            try await services.timing.sleepUntil(lastAttempt.addingTimeInterval(Self.cadence))
            try Task.checkCancellation()
            do {
                if try await publishLatest(services) { changed.yield() }
                if failed { Self.log.notice("实时活动推送恢复") }
                failed = false
                retry.reset()
                // 刚完的留到点那一刻库里没有变化：自己醒一次去结束
                lingering?.cancel()
                lingering = lingersUntil.map { until in
                    Task { if (try? await services.timing.sleepUntil(until)) != nil { changed.yield() } }
                }
            } catch where !Task.isCancelled {
                if !failed { Self.log.error("实时活动推送未送达，保留最新一份重试：\(String(describing: error), privacy: .public)") }
                failed = true
                try await services.timing.sleep(retry.next())
                changed.yield()
            }
        }
    }

    private struct Publication {
        var destinations: [ActivityDestination]
        var state: CueActivityState

        func same(as other: Self) -> Bool { destinations == other.destinations && state.same(as: other.state) }
    }

    /// 订阅只负责叫醒；网络返回时订阅重读未必已送到，不以它缓存的那一份证明问题仍有效。
    private func current(_ services: AppServices) throws -> Publication? {
        let read = try services.store.snapshot { try CueReading.Read.read(from: $0, widget: false) }.value
        guard let activity = read.activity, activity.publisher == services.hostID, let state = try services.activityState(read.digest) else { return nil }
        return Publication(destinations: activity.destinations, state: state)
    }

    /// 内容在等待期间前进了就交回合并流（返回 true），只追最新一份，不在这里循环追赶。
    private func publishLatest(_ services: AppServices) async throws -> Bool {
        guard let publication = try current(services) else {
            for device in sent.keys { leave(device) }
            lingersUntil = nil
            return false
        }
        let now = publication.state.now
        lingersUntil = now.isLive && !now.hasConfirmedActivity && !now.unconfirmed ? now.lingersUntil : nil
        let devices = Dictionary(grouping: publication.destinations, by: \.device)
        // 手机删了地址：那只岛结束了或被划掉了
        for device in sent.keys where devices[device]?.contains(where: { !$0.isStarter }) != true { leave(device) }
        for device in devices.keys.sorted() {
            try Task.checkCancellation()
            let destination = devices[device]?.first { !$0.isStarter }
            if let destination, destination.expiresAt > .now, islands[device]?.ended != destination.activityID {
                if try await update(destination, publication, services) { return true }
            } else if let starter = devices[device]?.first(where: \.isStarter) {
                // 没等这台来收就过了系统上限的那只：从上限那一刻算没了
                if let destination, islands[device]?.ended != destination.activityID { leave(device, ending: destination.activityID, at: destination.expiresAt) }
                if try await start(starter, publication, services) { return true }
            }
        }
        return false
    }

    private func leave(_ device: String, ending activity: String? = nil, at date: Date = .now) {
        sent[device] = nil
        var island = islands[device] ?? Island(gone: launched)
        island.gone = max(island.gone, date)
        if let activity { island.ended = activity }
        islands[device] = island
    }

    /// 可作答的提问先让 iCloud 收下（手机按"允许一次"时要找得到它）；等的时候内容前进了返回 nil。
    private func confirmed(_ publication: Publication, _ services: AppServices) async throws -> Publication? {
        guard let allow = publication.state.now.first?.allow else { return publication }
        guard await services.sync?.send(recordNames: [allow.message.uuidString.lowercased()]) == true else { throw URLError(.cannotLoadFromNetwork) }
        try Task.checkCancellation()
        guard let fresh = try current(services), fresh.same(as: publication) else { return nil }
        return fresh
    }

    private func update(_ destination: ActivityDestination, _ publication: Publication, _ services: AppServices) async throws -> Bool {
        let device = destination.device
        func push(_ payload: ActivityPush.Payload, priority: Int) async throws -> Bool {
            lastAttempt = .now
            return try await send(ActivityPush(
                token: destination.token, environment: destination.environment, priority: priority,
                expiration: Int(destination.expiresAt.timeIntervalSince1970), payload: payload))
        }
        if destination.retireAt <= .now {
            _ = try await push(.clearing(publication.state), priority: 10)
            Self.log.notice("实时活动快到系统上限，已结束并清掉")
            leave(device, ending: destination.activityID)
            return false
        }
        let old = sent[device]
        if let old, old.destination == destination, old.state.same(as: publication.state) { return false }
        guard let publication = try await confirmed(publication, services) else { return true }
        let now = publication.state.now, before = old?.state.now
        let urgent = !now.isLive || before?.needsYou != now.needsYou || before?.first != now.first || before?.glance != now.glance
        // false：令牌已被 APNs 确认失效，那只岛不在了
        if try await push(.init(publication.state), priority: urgent ? 10 : 5), now.isLive {
            sent[device] = Sent(destination: destination, state: publication.state)
        } else {
            leave(device, ending: destination.activityID)
        }
        try Task.checkCancellation()
        guard let fresh = try current(services), fresh.same(as: publication) else { return true }
        return false
    }

    private func start(_ starter: ActivityDestination, _ publication: Publication, _ services: AppServices) async throws -> Bool {
        let device = starter.device, island = islands[device] ?? Island(gone: launched)
        guard publication.state.now.hasConfirmedActivity, let newest = publication.state.now.newest, newest.since > island.gone,
              island.started.map({ Date.now.timeIntervalSince($0) >= Self.startSpacing }) ?? true else { return false }
        guard let publication = try await confirmed(publication, services) else { return true }
        lastAttempt = .now
        islands[device] = Island(gone: .now, ended: island.ended, started: .now)
        // 开没开出来这里不重试：同一件事再推一次只是再亮一次屏、再占一次额度，没开出来的留给手机到前台自己开
        do {
            let accepted = try await send(ActivityPush(
                token: starter.token, environment: starter.environment, priority: 10,
                expiration: Int(Date.now.addingTimeInterval(Self.startLifetime).timeIntervalSince1970),
                payload: .starting(
                    publication.state, startedAt: .now, title: newest.name,
                    body: newest.kind == .asks ? "island_start_asks" : "island_start_working")))
            Self.log.notice("远程开实时活动：\(accepted ? "APNs 收下" : "开岛令牌已失效，等手机换新的", privacy: .public)（\(newest.kind.rawValue, privacy: .public)）")
        } catch where !Task.isCancelled {
            Self.log.error("远程开实时活动未送达：\(String(describing: error), privacy: .public)")
        }
        try Task.checkCancellation()
        guard let fresh = try current(services), fresh.same(as: publication) else { return true }
        return false
    }

    /// false 只表示这个令牌已被 APNs 确认失效；不删手机拥有的同步记录，换令牌后会重试。
    private func send(_ push: ActivityPush) async throws -> Bool {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(push)
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 204 { return true }
        if response.statusCode == 410 { return false }
        throw Rejected(status: response.statusCode, reason: String(data: body, encoding: .utf8) ?? "")
    }

    private struct Rejected: Error {
        var status: Int
        var reason: String
    }
}

extension AppServices {
    func startActivityPushes() {
        guard relay != nil else { return }
        let publisher = ActivityPublisher(host: Self.relayHost)
        follow { await publisher.run(self) }
    }
}
#endif
