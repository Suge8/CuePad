#if os(macOS)
import CueStore
import CueSync
import Foundation
import Observation
import OSLog

/// 开着的岛由 Mac 唯一发布内容，手机只登记地址；中转不存业务状态。
/// 观察复用 CueFeed，同一秒内只发最新一份（APNs timestamp 是秒）；网络慢或失败时不排历史队列。
/// 成功只表示 APNs 收下，不表示已上屏。普通进度低优先级，等你变化和结束用高优先级；不以高频推送耗尽系统预算。
final class ActivityPublisher {
    private let endpoint: URL
    private let session: URLSession
    private var latest: CueFeed.Seen?
    private var sent: [String: Sent] = [:]
    private var lastAttempt = Date.distantPast
    private static let log = Logger(subsystem: AppIdentity.id, category: "live-activity")
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

    func run(_ services: AppServices) async throws {
        defer { session.invalidateAndCancel() }
        let (changes, changed) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let reading: @MainActor @Sendable () async throws -> Void = {
            defer { changed.finish() }
            for try await seen in services.cueUpdates() {
                self.latest = seen
                changed.yield()
            }
        }
        let availability: @MainActor @Sendable () async throws -> Void = {
            for await _ in Observations({ services.syncStatus.reachesMac && services.knowsSyncedFacts }) { changed.yield() }
        }
        let publishing: @MainActor @Sendable () async throws -> Void = {
            try await self.publish(changes, retrying: changed, services: services)
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
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
            guard let seen = latest, let activity = seen.read.activity, activity.publisher == services.hostID,
                  services.syncStatus.reachesMac, services.knowsSyncedFacts else {
                sent.removeAll()
                continue
            }
            let now = AppServices.cueNow(seen.read.digest, at: seen.moment, local: CueNow.Local(waiting: nil, here: nil))
            let state = try ActivityPush.fitted(CueActivityState(now: now, quotas: activity.quotas))
            sent = sent.filter { key, _ in activity.destinations.contains { $0.device == key } }
            do {
                for destination in activity.destinations where destination.expiresAt > .now {
                    try Task.checkCancellation()
                    let old = sent[destination.device]
                    if old?.destination == destination, old?.state.map({ $0.same(as: state) }) ?? true { continue }
                    let priority = !now.isLive || old?.state?.now.needsYou != now.needsYou || old?.state?.now.first != now.first ? 10 : 5
                    lastAttempt = .now
                    let accepted = try await send(ActivityPush(
                        token: destination.token, environment: destination.environment, priority: priority,
                        expiration: Int(destination.expiresAt.timeIntervalSince1970), payload: .init(state)))
                    sent[destination.device] = Sent(destination: destination, state: accepted && now.isLive ? state : nil)
                }
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
        follow(reporting: { .widgetDataUnavailable("\($0)") }) { try await publisher.run(self) }
    }
}
#endif
