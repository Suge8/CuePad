#if os(iOS)
import ActivityKit
import CryptoKit
import CueStore
import Foundation

extension CueLiveActivity {
    var pushEnvironment: String? {
        guard let environment = Bundle.main.object(forInfoDictionaryKey: "CuePadPushEnvironment") as? String,
              ["development", "production"].contains(environment) else { return nil }
        return environment
    }

    func observe(_ activity: Activity<CueActivityAttributes>) {
        guard sync != nil, observers[activity.id] == nil else { return }
        let revision = revision
        let tokens = Task { [weak self] in
            if let token = activity.pushToken { await self?.record(token, for: activity, revision: revision) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.record(token, for: activity, revision: revision)
            }
        }
        let states = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self, !Task.isCancelled, revision == self.revision else { return }
                await removeDestination(activityID: activity.id, reason: "\(state)")
                for task in observers.removeValue(forKey: activity.id) ?? [] { task.cancel() }
                return
            }
        }
        observers[activity.id] = [tokens, states]
    }

    /// 开岛令牌的初值与轮换、系统（远程推送）开出来的活动。自己请求的那只在 `present` 里已登记，`adopt` 按 `observers` 认出、不重复。
    func watchRemoteStarts() -> [Task<Void, Never>] {
        [
            Task { [weak self] in
                await self?.registerStarter()
                for await _ in Activity<CueActivityAttributes>.pushToStartTokenUpdates {
                    guard !Task.isCancelled else { return }
                    await self?.registerStarter()
                }
            },
            Task { [weak self] in
                for await _ in Activity<CueActivityAttributes>.activityUpdates {
                    guard !Task.isCancelled else { return }
                    await self?.adopt()
                }
            },
        ]
    }

    /// 资料所属刚确认（同步对过）：此前到的开岛令牌与远程开出来的活动那时不能登记，现在补上。被推送冷启动的进程走的就是这条。
    func syncReady() async {
        await registerStarter()
        await adopt()
    }

    /// 和登记活动地址同一个前提：资料所属确认过（`remoteState`）才把这台手机的地址写进它的 iCloud。
    func registerStarter() async {
        guard sync != nil, let device, let environment = pushEnvironment, let token = Activity<CueActivityAttributes>.pushToStartToken,
              (try? remoteState()) != nil else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard hex != starterToken else { return }
        starterToken = hex
        await changeDestination(activityID: nil, reason: "starter") {
            try await self.store.recordActivityStarter(device: device, token: hex, environment: environment).map { (record: $0, activity: "") }
        }
    }

    func removeStarter(reason: String) async {
        starterToken = nil
        guard sync != nil, let device else { return }
        await changeDestination(deleting: true, activityID: nil, reason: "\(reason)/starter") {
            try await self.store.removeActivityStarter(device: device).map { (record: $0, activity: "") }
        }
    }

    /// 远程开出来、还没登记地址的那只：登记了 Mac 才推得动。同时还开着别的（旧的没收到结束）就只留最新一只。
    /// 和 `show` 等同一个撤销屏障；资料所属没确认时不接，等 `syncReady`。
    private func adopt() async {
        let revision = revision
        await restoration?.value
        guard revision == self.revision, !Task.isCancelled, sync != nil, (try? remoteState()) != nil,
              let newest = Self.running.first, newest.attributes.remoteUpdates == true, observers[newest.id] == nil else { return }
        trace(.created, activityID: newest.id, reason: "adopt", content: newest.content.state)
        observeDiagnostics(newest)
        for extra in Self.running.dropFirst() {
            trace(.endRequested, activityID: extra.id, reason: "adoptExtra")
            await extra.end(nil, dismissalPolicy: .immediate, timestamp: .now)
            await removeDestination(activityID: extra.id, reason: "adoptExtra")
        }
        guard revision == self.revision, Self.running.first?.id == newest.id, observers[newest.id] == nil else { return }
        observe(newest)
    }

    private func record(_ token: Data, for activity: Activity<CueActivityAttributes>, revision: UUID) async {
        guard !Task.isCancelled, revision == self.revision, let device, let environment = pushEnvironment, let startedAt = activity.attributes.startedAt,
              Self.running.first?.id == activity.id else {
            trace(.destinationResult, activityID: activity.id, reason: "register/ineligible")
            return
        }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let tag = SHA256.hash(data: Data(hex.utf8)).map { String(format: "%02x", $0) }.joined()
        trace(.destinationWrite, activityID: activity.id, tokenTag: tag)
        await changeDestination(activityID: activity.id, reason: "register") {
            guard !Task.isCancelled, revision == self.revision, Self.running.first?.id == activity.id else {
                self.trace(.blocked, activityID: activity.id, reason: "register/ineligibleAfterQueue")
                return nil
            }
            let id = try await self.store.recordActivityDestination(
                device: device, activityID: activity.id, token: hex,
                environment: environment, startedAt: startedAt)
            return id.map { (record: $0, activity: activity.id) }
        }
    }

    func removeDestination(activityID: String?, reason: String) async {
        guard sync != nil, let device else {
            trace(.destinationResult, activityID: activityID, reason: "\(reason)/remove/unavailable")
            return
        }
        await changeDestination(deleting: true, activityID: activityID, reason: reason) {
            let removed = try await self.store.removeActivityDestination(device: device, activityID: activityID)
            self.traceDestinationRemoval(requested: activityID, removed: removed, reason: reason)
            return removed.map { (record: ActivityDestination.recordID(device: $0.device), activity: $0.activityID) }
        }
    }

    /// 只串行化地址的有限写入，不等 ActivityKit 的长订阅退出（令牌流取消后仍可能悬着）。
    /// 撤销排在已入途的写入之后；下一次开启又等撤销完成，旧写入无法覆盖新地址。
    private func changeDestination(
        deleting: Bool = false, activityID: String?, reason: String,
        _ change: @escaping () async throws -> (record: UUID, activity: String)?
    ) async {
        let previous = destinationWork, revision = revision
        let operation = "\(reason)/\(deleting ? "delete" : "save")"
        let task = Task {
            await previous?.value
            await BackgroundWork.run {
                do {
                    guard revision == self.revision else {
                        trace(.destinationResult, activityID: activityID, reason: "\(operation)/superseded")
                        return
                    }
                    guard let changed = try await change() else {
                        trace(.destinationResult, activityID: activityID, reason: "\(operation)/noChange")
                        return
                    }
                    guard revision == self.revision else {
                        trace(.destinationResult, activityID: changed.activity, reason: "\(operation)/supersededAfterWrite")
                        return
                    }
                    let accepted = await sync?.send(recordNames: [changed.record.uuidString.lowercased()]) == true
                    trace(.destinationResult, activityID: changed.activity, reason: "\(operation)/\(accepted ? "cloudAccepted" : "notConfirmed")")
                } catch {
                    trace(.destinationResult, activityID: activityID, reason: "\(operation)/error", error: error)
                    Self.log.error("实时活动推送地址没能更新：\((error as NSError).domain, privacy: .public) \((error as NSError).code)")
                }
            }
        }
        destinationWork = task
        await task.value
    }
}
#endif
