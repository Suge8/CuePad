#if os(macOS)
import AppKit
import CueStore
import Foundation
import os
import Synchronization

/// 这台 Mac 的在线记录（`MacPresence`，各端判断它在不在线、Cue 在不在值班的唯一信号）只由这里写，每次写完立即上传：
/// 启动与醒来立即续期，醒着每 `MacPresence.renewal` 续一次；系统将睡眠与退出（`AppServices.beginShutdown`）时写成离线。
/// 将睡眠的通知同步处理：观察者不返回系统就不睡（至多 30 秒，见 `NSWorkspace.willSleepNotification` 的文档），离线这一条写完、传完
/// （至多 `sleepUploadLimit`）才放行。异步处理时，合上盖子网络常在上传前就断了，别的设备要等期限过了才知道它不在。
/// 醒没醒只看系统的将睡眠与醒来（醒来只在完整唤醒时发，睡眠中的维护唤醒不算），睡着时定时器到点不续。
nonisolated final class MacPresenceKeeper: Sendable {
    /// 将睡眠时等离线这一条传完的上限：一次上传通常 1 秒内，实测偶尔约 10 秒（issue #2）；系统最多等 30 秒，这里不拖满。
    static let sleepUploadLimit: TimeInterval = 10

    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let host: String
    private let awake = Mutex(true)
    private static let log = Logger(subsystem: AppIdentity.id, category: "services")

    init(store: CueStore, sync: (any SyncControlling)?, host: String) {
        self.store = store
        self.sync = sync
        self.host = host
    }

    func keep(notifications center: NotificationCenter) async throws {
        let sleeping = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [self] _ in
            goingToSleep()
        }
        defer { center.removeObserver(sleeping) }
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                    self.awake.withLock { $0 = true }
                    try await self.publish()
                }
            }
            group.addTask {
                repeat {
                    if self.awake.withLock({ $0 }) { try await self.publish() }
                } while (try? await self.store.timing.sleep(MacPresence.renewal)) != nil
            }
        }
    }

    func signOff() async {
        awake.withLock { $0 = false }
        do { try await publish() } catch { Self.log.error("退出时没能写下这台 Mac 离线：\(error.localizedDescription, privacy: .public)") }
    }

    /// 在系统发将睡眠通知的线程上同步等离线这一条写完、传完：这是系统给的唯一一段能拖住睡眠的时间（等的工作不在主线程上，不会互等）。
    private func goingToSleep() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await signOff()
            done.signal()
        }
        if done.wait(timeout: .now() + Self.sleepUploadLimit) == .timedOut {
            Self.log.notice("将睡眠：这台 Mac 离线的记录 \(Int(Self.sleepUploadLimit)) 秒内没传完，别的设备等期限过了才知道")
        }
    }

    private func publish() async throws {
        let id = try await store.recordMacPresence(host: host) { self.awake.withLock { $0 } }
        await sync?.upload(id)
    }
}
#endif
