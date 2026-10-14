#if os(iOS)
import Synchronization
import SwiftUI

/// 每个窗口的壳：注入通知、处理深链接、进入后台前落盘；有同步时开启 Pi 通知。
struct SceneRoot: View {
    let services: AppServices
    let alerts: PiAlertCenter

    init(services: AppServices, alerts: PiAlertCenter) {
        self.services = services
        self.alerts = alerts
        alerts.services = services
    }
    @Environment(\.scenePhase) private var phase

    var body: some View {
        IOSRoot(services: services, alerts: alerts)
            .environment(alerts)
            .task { if services.sync != nil { await alerts.enable() } }
            .onOpenURL { services.handle(url: $0) }
            .onChange(of: phase) { _, phase in
                switch phase {
                case .active: Task {
                    await alerts.refresh()
                    await services.drainCaptures()
                    await services.handleActivation()
                }
                case .background: Task { await BackgroundWork.run { await services.prepareForBackground() } }
                default: break
                }
            }
    }
}

/// 让进入后台后的收尾工作有时间跑完（系统随后才挂起进程）。
enum BackgroundWork {
    static func run(_ work: @MainActor () async -> Void) async {
        // 到期回调与下面的收尾都要用这个标识，回调先于赋值的窗口只有一瞬，用锁盒子传
        let task = Mutex(UIBackgroundTaskIdentifier.invalid)
        let id = UIApplication.shared.beginBackgroundTask(withName: "CuePad.flush") {
            UIApplication.shared.endBackgroundTask(task.withLock { $0 })
        }
        task.withLock { $0 = id }
        await work()
        UIApplication.shared.endBackgroundTask(id)
    }
}
#endif
