#if os(iOS)
import Synchronization
import SwiftUI

/// 每个窗口的壳：注入通知、处理深链接、进入后台前落盘；有同步时开启 Pi 通知。
/// 这里的 body 不随什么重算（前后台在 `ScenePhaseWork` 里看）：窗口的根视图只建一次，建工作区时当场读库（`Workspace.init`）不白读。
struct SceneRoot: View {
    let services: AppServices
    let alerts: AlertCenter

    init(services: AppServices, alerts: AlertCenter) {
        self.services = services
        self.alerts = alerts
        alerts.services = services
    }

    var body: some View {
        IOSRoot(services: services, alerts: alerts)
            .environment(alerts)
            .task { if services.sync != nil { await alerts.enable() } }
            .onOpenURL { services.handle(url: $0) }
            .modifier(ScenePhaseWork(services: services, alerts: alerts))
    }
}

/// 回到前台：刷新通知、收分享、立即同步；进入后台：落盘。
private struct ScenePhaseWork: ViewModifier {
    let services: AppServices
    let alerts: AlertCenter
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
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
