#if os(macOS)
import CueStore
import CueSync
import Foundation
import Observation
import OSLog

/// 开着的岛由 Mac 唯一发布内容，手机只登记地址；中转不存业务状态。
/// 同一秒内只发最新一份（APNs timestamp 是秒）；网络慢或失败时不排历史队列。
/// 可作答的提问先确认 iCloud 收下；每次等待后从库核对当前内容，不把已撤回或回答的旧提问补推回去。
/// 成功只表示 APNs 收下，不表示已上屏。普通进度用低优先级，免得高频推送耗尽系统预算。
/// 读库、推送出错都只记日志、按退避再来，跟着 App 一直跑到取消：Mac 上没有别处能告诉你，停下就再也不推了。
final class ActivityPublisher {
    private let endpoint: URL
    private let session: URLSession
    private var sent: [String: Sent] = [:]
    private var lastAttempt = Date.distantPast
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "live-activity")
    private static let requestLimit: TimeInterval = 15
    private static let cadence: TimeInterval = 1

    private struct Sent {
        var destination: ActivityDestination
        var state: CueActivityState?
    }

    init(host: String) {
        endpoint = URL(string: "https://\(host)/v1/activity")!
        let configuration = URLSessionConfiguration.ephemeral
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
        for await _ in changes {
            try await services.timing.sleepUntil(lastAttempt.addingTimeInterval(Self.cadence))
            try Task.checkCancellation()
            do {
                if try await publishLatest(services) { changed.yield() }
                if failed { Self.log.notice("实时活动推送恢复") }
                failed = false
                retry.reset()
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

    /// 内容在等待期间前进了就交回合并流，只追最新一份，不在这里循环追赶。
    private func publishLatest(_ services: AppServices) async throws -> Bool {
        guard var publication = try current(services) else {
            sent.removeAll()
            return false
        }
        sent = sent.filter { key, _ in publication.destinations.contains { $0.device == key } }
        for destination in publication.destinations where destination.expiresAt > .now {
            try Task.checkCancellation()
            let old = sent[destination.device]
            if old?.destination == destination, old?.state.map({ $0.same(as: publication.state) }) ?? true { continue }
            if let allow = publication.state.now.first?.allow {
                guard await services.sync?.send(recordNames: [allow.message.uuidString.lowercased()]) == true else {
                    throw URLError(.cannotLoadFromNetwork)
                }
                try Task.checkCancellation()
                guard let fresh = try current(services), fresh.same(as: publication) else { return true }
                publication = fresh
            }
            let now = publication.state.now
            let priority = !now.isLive || old?.state?.now.needsYou != now.needsYou || old?.state?.now.first != now.first ? 10 : 5
            lastAttempt = .now
            let accepted = try await send(ActivityPush(
                token: destination.token, environment: destination.environment, priority: priority,
                expiration: Int(destination.expiresAt.timeIntervalSince1970), payload: .init(publication.state)))
            sent[destination.device] = Sent(destination: destination, state: accepted && now.isLive ? publication.state : nil)
            try Task.checkCancellation()
            guard let fresh = try current(services), fresh.same(as: publication) else { return true }
            publication = fresh
        }
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
