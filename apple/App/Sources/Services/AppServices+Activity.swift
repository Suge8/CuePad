#if os(macOS)
import CueStore
import Foundation
import os

/// 有等待理由（`pollingCadence` 不为 nil）期间持有系统活动，不让 App Nap 节流按节奏的拉取。
///
/// 用户离开后 App Nap 把 App 放进后台节流档（只在能效核、最低优先级）：别的程序占满 CPU 时进程整段拿不到 CPU，2 秒一拉能停几分钟
/// （2026-10-24 复现：拉取间隔最长 210 秒；持有活动、负载更高时最长 4.8 秒）。Mac 不收推送，这一拉是别的设备写来的东西到达的唯一通路
/// （docs/sync.md「拉取节奏」），所以等的期间接受不进 App Nap 的能耗；不阻止系统睡眠，没有等待理由就放掉。
///
/// 持有期间每秒量一次拉取要经过的两条串行通道（主线程、资料库队列）的排队与进程自己有没有被调度，超过 `stallLimit` 记一条
/// （类别 stall，notice 级别落盘）：下次停摆从日志就看得出卡在哪，不用旁听推断。
extension AppServices {
    func holdActivityWhilePolling() {
        follow { [store] in
            var held: (activity: NSObjectProtocol, watch: Task<Void, Never>)?
            for await waiting in Observations({ self.pollingCadence != nil }) where waiting != (held != nil) {
                if let (activity, watch) = held {
                    ProcessInfo.processInfo.endActivity(activity)
                    watch.cancel()
                    held = nil
                } else {
                    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "按节奏从 iCloud 拉取")
                    held = (activity, Task { await Self.watchStalls(store) })
                }
            }
            if let (activity, watch) = held {
                ProcessInfo.processInfo.endActivity(activity)
                watch.cancel()
            }
        }
    }

    nonisolated private static let stallLimit = Duration.seconds(1)
    nonisolated private static let stallLog = Logger(subsystem: AppIdentity.id, category: "stall")

    @concurrent private static func watchStalls(_ store: CueStore) async {
        let clock = ContinuousClock()
        while true {
            let asked = clock.now
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            let late = clock.now - asked - .seconds(1)
            async let main = clock.measure { await MainActor.run {} }
            async let library = store.queueDelay()
            let (mainDelay, libraryDelay) = await (main, library)
            guard max(late, mainDelay, libraryDelay) > stallLimit else { continue }
            stallLog.notice(
                "停摆：进程晚醒 \(late.milliseconds, privacy: .public)ms，主线程排队 \(mainDelay.milliseconds, privacy: .public)ms，资料库队列排队 \(libraryDelay.milliseconds, privacy: .public)ms")
        }
    }
}

extension Duration {
    nonisolated fileprivate var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
#endif
