#if os(iOS)
import SwiftUI

/// 每个窗口的壳：注入通知、处理深链接、进入后台前落盘；有同步时开启 Pi 通知。
struct SceneRoot: View {
    let services: AppServices
    let alerts: PiAlertCenter
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
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "CuePad.flush") {
            UIApplication.shared.endBackgroundTask(task)
        }
        await work()
        UIApplication.shared.endBackgroundTask(task)
    }
}
#endif
