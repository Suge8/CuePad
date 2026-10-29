#if os(iOS)
import ActivityKit
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
                await removeDestination(activityID: activity.id)
                for task in observers.removeValue(forKey: activity.id) ?? [] { task.cancel() }
                return
            }
        }
        observers[activity.id] = [tokens, states]
    }

    private func record(_ token: Data, for activity: Activity<CueActivityAttributes>, revision: UUID) async {
        guard !Task.isCancelled, revision == self.revision, let device, let environment = pushEnvironment, let startedAt = activity.attributes.startedAt,
              Self.running.first?.id == activity.id else { return }
        await changeDestination {
            guard !Task.isCancelled, revision == self.revision, Self.running.first?.id == activity.id else { return nil }
            return try await self.store.recordActivityDestination(
                device: device, activityID: activity.id, token: token.map { String(format: "%02x", $0) }.joined(),
                environment: environment, startedAt: startedAt)
        }
    }

    func removeDestination(activityID: String?) async {
        guard sync != nil, let device else { return }
        await changeDestination(deleting: true) {
            try await self.store.removeActivityDestination(device: device, activityID: activityID)
        }
    }

    /// 只串行化地址的有限写入，不等 ActivityKit 的长订阅退出（令牌流取消后仍可能悬着）。
    /// 撤销排在已入途的写入之后；下一次开启又等撤销完成，旧写入无法覆盖新地址。
    private func changeDestination(deleting: Bool = false, _ change: @escaping () async throws -> UUID?) async {
        let previous = destinationWork, revision = revision
        let task = Task {
            await previous?.value
            await BackgroundWork.run {
                do {
                    guard revision == self.revision else { return }
                    if let id = try await change(), revision == self.revision {
                        await sync?.upload([id], deleted: deleting)
                    }
                } catch {
                    Self.log.error("实时活动推送地址没能更新：\(String(describing: error), privacy: .private)")
                }
            }
        }
        destinationWork = task
        await task.value
    }
}
#endif
