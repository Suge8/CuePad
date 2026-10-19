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
        // 到期回调与做完的收尾谁先到谁结束、只结束一次（到期后再结束同一个标识系统会报错）；回调先于赋值的窗口只有一瞬，用锁盒子传
        let task = Mutex(UIBackgroundTaskIdentifier.invalid)
        let end: @MainActor () -> Void = {
            let id = task.withLock { id in
                defer { id = .invalid }
                return id
            }
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
        let id = UIApplication.shared.beginBackgroundTask(withName: "CuePad.flush") { end() }
        task.withLock { $0 = id }
        await work()
        end()
    }
}

/// 进后台时系统把窗口场景切到另一种外观拍一张快照再切回来（App 切换器里备用的那张）。切过去的那一遍在快照里当场画完；切回来的那一遍
/// 排在快照的后台任务结束之后，SwiftUI 要把整窗的字按新外观重排一遍（几十到几百毫秒），这段时间只靠别的后台任务碰巧撑着，
/// 进程等不到它画完就被挂起时窗口停在另一种外观上，回前台先露出它再翻回来——浅色下切回来闪一下深色。
/// 后台里外观每变一次，这里当场撑住进程，等切回那一遍画完、提交给渲染再放。
enum AppearanceSettle {
    /// 启动时登记一次：之后连上的每个窗口场景都看着。
    static func watch() {
        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            MainActor.assumeIsolated {
                _ = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (scene: UIWindowScene, _) in hold(scene) }
            }
        }
    }

    private static func hold(_ scene: UIWindowScene) {
        guard scene.activationState == .background else { return }
        let task = UIApplication.shared.beginBackgroundTask(withName: "CuePad.appearance")
        // UIKit 先把 SwiftUI 按新外观重画的那一遍排进主队列、再通知外观的观察者，排在它后面就是等它画完；
        // 同一轮主队列里它画的还没提交，先提交再放
        DispatchQueue.main.async {
            CATransaction.flush()
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
#endif
