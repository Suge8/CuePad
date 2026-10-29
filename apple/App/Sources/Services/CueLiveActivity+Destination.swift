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
        let tokens = Task { [weak self] in
            if let token = activity.pushToken { await self?.record(token, for: activity) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.record(token, for: activity)
            }
        }
        let states = Task { [weak self] in
            for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                guard let self else { return }
                await removeDestination(activityID: activity.id)
                for task in observers.removeValue(forKey: activity.id) ?? [] { task.cancel() }
                return
            }
        }
        observers[activity.id] = [tokens, states]
    }

    private func record(_ token: Data, for activity: Activity<CueActivityAttributes>) async {
        guard let device, let environment = pushEnvironment, let startedAt = activity.attributes.startedAt,
              Self.running.first?.id == activity.id else { return }
        await BackgroundWork.run {
            do {
                if let id = try await store.recordActivityDestination(
                    device: device, activityID: activity.id, token: token.map { String(format: "%02x", $0) }.joined(),
                    environment: environment, startedAt: startedAt) {
                    await sync?.upload(id)
                }
            } catch {
                Self.log.error("实时活动推送地址没能保存：\(String(describing: error), privacy: .private)")
            }
        }
    }

    func removeDestination(activityID: String?) async {
        guard sync != nil, let device else { return }
        await BackgroundWork.run {
            do {
                if let id = try await store.removeActivityDestination(device: device, activityID: activityID) {
                    await sync?.upload([id], deleted: true)
                }
            } catch {
                Self.log.error("实时活动推送地址没能移除：\(String(describing: error), privacy: .private)")
            }
        }
    }
}
#endif
