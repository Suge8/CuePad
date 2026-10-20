#if os(iOS)
import Synchronization
import SwiftUI

/// 每个窗口的壳：注入通知、处理深链接、进入后台前落盘、后台里换了外观当场画完（`AppearanceSettle`）；有同步时开启 Pi 通知。
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
            .task { if services.sync != nil || DebugHooks.deliversNotifications { await alerts.enable() } }
            .onOpenURL { services.handle(url: $0) }
            .modifier(ScenePhaseWork(services: services, alerts: alerts))
            .background { AppearanceSettle() }
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

/// 进后台时系统把窗口切到另一种外观拍一张快照再切回来（App 切换器里备用的那张）。切过去的那一遍在快照里当场画完；切回来的那一遍
/// SwiftUI 只排进主队列，等到时快照的后台任务已经结束，整窗的字按新外观重排（几十到几百毫秒）只靠别的后台任务碰巧撑着，
/// 进程等不到它画完就被挂起时窗口停在另一种外观上，回前台先露出它再翻回来——浅色下切回来闪一下深色。
/// 这里盯着本窗口的宿主视图：后台里它的外观一变（SwiftUI 此时已拿到新外观），就在撑住进程的这一下里把宿主和它弹出的页当场画完、提交给渲染，
/// SwiftUI 排着的那一遍到时已无事可做。
private struct AppearanceSettle: UIViewRepresentable {
    func makeUIView(context: Context) -> Hook {
        let hook = Hook()
        hook.isUserInteractionEnabled = false
        return hook
    }
    func updateUIView(_ hook: Hook, context: Context) {}

    final class Hook: UIView {
        private weak var host: UIView?
        private var registration: (any UITraitChangeRegistration)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let registration { host?.unregisterForTraitChanges(registration) }
            host = window?.rootViewController?.view
            registration = host?.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (host: UIView, _) in Self.settle(host) }
        }

        private static func settle(_ host: UIView) {
            guard let window = host.window, window.windowScene?.activationState == .background else { return }
            let task = UIApplication.shared.beginBackgroundTask(withName: "CuePad.appearance")
            defer { UIApplication.shared.endBackgroundTask(task) }
            var controller = window.rootViewController
            while let shown = controller {
                // SwiftUI 拿到新外观只排了一遍异步重画、宿主并不脏：标脏再排，才当场按新外观画
                shown.view.setNeedsLayout()
                shown.view.layoutIfNeeded()
                controller = shown.presentedViewController
            }
            CATransaction.flush()
        }
    }
}
#endif
