#if os(iOS)
import Synchronization
import SwiftUI

/// 每个窗口的壳：注入通知、处理深链接、进入后台前落盘、定场景的外观（`SceneAppearance`）；有同步时开启 Pi 通知。
/// 这里的 body 不随什么重算（前后台在 `ScenePhaseWork` 里看）：窗口的根视图只建一次，建工作区时当场读库（`Workspace.init`）不白读。
struct SceneRoot: View {
    let services: AppServices
    let alerts: AlertCenter

    var body: some View {
        IOSRoot(services: services)
            .debugCompact()
            .environment(alerts)
            .task { if services.sync != nil { await alerts.enable() } }
            .onOpenURL { services.handle(url: $0) }
            .modifier(ScenePhaseWork(services: services))
            .background { SceneAppearance(settings: services.settings) }
    }
}

/// 最后一个窗口退到后台：落盘、传完、断开（`prepareForBackground`）。回到前台整个 App 只做一次，不在这里（`AppServices.startForeground`）。
/// iPad 多窗口时只退下一个、别的还在前台，App 照常拉取、连着门铃。
private struct ScenePhaseWork: ViewModifier {
    let services: AppServices
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .onChange(of: phase) { _, phase in
                guard phase == .background, UIApplication.shared.connectedScenes.allSatisfy({ $0.activationState == .background }) else { return }
                Task { await BackgroundWork.run { await services.prepareForBackground() } }
            }
    }
}

/// 让后台里的工作有时间跑完（系统随后才挂起进程）：进入后台后的收尾，后台里短连门铃（`Relay`）。
enum BackgroundWork {
    static func run(_ work: @MainActor () async -> Void) async {
        let end = begin()
        await work()
        end()
    }

    /// 当场开始，返回结束它的那一下（只认第一次）。
    static func begin() -> @MainActor @Sendable () -> Void {
        // 到期回调与做完的收尾谁先到谁结束、只结束一次（到期后再结束同一个标识系统会报错）；回调先于赋值的窗口只有一瞬，用锁盒子传
        let task = Mutex(UIBackgroundTaskIdentifier.invalid)
        let end: @MainActor @Sendable () -> Void = {
            let id = task.withLock { id in
                defer { id = .invalid }
                return id
            }
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
        let id = UIApplication.shared.beginBackgroundTask(withName: "CuePad.flush") { end() }
        task.withLock { $0 = id }
        return end
    }
}

/// 场景的外观只在这里定（`UIWindowScene.traitOverrides`）：设置里选了浅色、深色就钉成它；跟随系统时在前台不钉，进后台时钉在当时的外观，回前台再放开。
/// 不钉时，系统每次进后台都把场景切到另一种外观拍一张备用快照再切回来，SwiftUI 在后台把整窗按两种外观各重画一遍；
/// 切回那遍没赶在挂起前画完，或回前台时拿到那张备用快照，就先露出另一种外观再翻回来。钉住后两张快照都是当时的外观，后台不重画。
/// 代价：App 挂起期间系统外观真变了，回来时快照还是旧外观，放开后才翻成新的（选了浅色、深色本来就这样）。
private struct SceneAppearance: View {
    let settings: AppSettings

    var body: some View { Applier(theme: settings.theme) }

    private struct Applier: UIViewRepresentable {
        let theme: AppSettings.Theme

        func makeUIView(context: Context) -> Hook {
            let hook = Hook()
            hook.isUserInteractionEnabled = false
            return hook
        }

        func updateUIView(_ hook: Hook, context: Context) { hook.theme = theme }
    }

    final class Hook: UIView {
        var theme = AppSettings.Theme.system { didSet { apply() } }
        private var backgrounded = false
        private var observers: [any NSObjectProtocol] = []

        override func didMoveToWindow() {
            super.didMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            let scene = window?.windowScene
            backgrounded = scene?.activationState == .background
            observers = [UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.backgrounded = name == UIScene.didEnterBackgroundNotification
                        self?.apply()
                    }
                }
            }
            apply()
        }

        private func apply() {
            guard let scene = window?.windowScene else { return }
            let pinned: UIUserInterfaceStyle? = switch theme {
            case .light: .light
            case .dark: .dark
            case .system: backgrounded ? scene.traitCollection.userInterfaceStyle : nil
            }
            if let pinned {
                scene.traitOverrides.userInterfaceStyle = pinned
            } else {
                scene.traitOverrides.remove(UITraitUserInterfaceStyle.self)
            }
        }
    }
}
#endif
