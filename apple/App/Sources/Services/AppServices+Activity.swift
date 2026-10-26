#if os(macOS)
import CueStore
import Foundation
import os

/// 有等待理由（`pollingCadence` 不为 nil）期间持有系统活动，不让 App Nap 节流按节奏的拉取。
///
/// 用户离开后 App Nap 把 App 放进后台节流档（只在能效核、最低优先级）：别的程序占满 CPU 时进程整段拿不到 CPU，按节奏的拉取能停几分钟
/// （实测见 docs/sync.md「用户离开时的 Mac」）。Mac 不收推送，门铃不通时这一拉是别的设备写来的东西到达的唯一通路，通着时它是兜底
/// （「拉取节奏与门铃」），所以等的期间接受不进 App Nap 的能耗；不阻止系统睡眠，没有等待理由就放掉。
/// 没有等待理由时门铃照样连着、不持有活动：中转空闲时自己发 ping、URLSession 自动回，本机心跳晚醒不让中转断开；
/// 整段拿不到 CPU 久到中转断开的，醒来重连、入房先拉一次。
///
/// 持有期间每秒量一次拉取要经过的两条串行通道（主线程、资料库队列）的排队与进程自己有没有被调度，超过 `stallLimit` 记一条
/// （类别 stall，notice 级别落盘）：下次停摆从日志就看得出卡在哪，不用旁听推断。
extension AppServices {
    func holdActivityWhilePolling() {
        follow { [store] in
            var held: (activity: NSObjectProtocol, watch: Task<Void, Never>)?
            func release() {
                guard let (activity, watch) = held else { return }
                ProcessInfo.processInfo.endActivity(activity)
                watch.cancel()
                held = nil
            }
            for await waiting in Observations({ self.pollingCadence != nil }) where waiting != (held != nil) {
                if held != nil {
                    release()
                } else {
                    let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "按节奏从 iCloud 拉取")
                    held = (activity, Task { await Self.watchStalls(store) })
                }
            }
            release()
        }
    }

    nonisolated private static let stallLimit = Duration.seconds(1)

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
            Logger.stall.notice(
                "停摆：进程晚醒 \(late.milliseconds, privacy: .public)ms，主线程排队 \(mainDelay.milliseconds, privacy: .public)ms，资料库队列排队 \(libraryDelay.milliseconds, privacy: .public)ms")
        }
    }
}

extension Duration {
    nonisolated fileprivate var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
#endif
