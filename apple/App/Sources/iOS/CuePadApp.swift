#if os(iOS)
import CueStore
import SwiftUI

@main
struct CuePadApp: App {
    /// 资料库与服务由它建、它持有（`IOSAppDelegate.launch`）：静默推送把 App 叫到后台时不一定建窗口，推送照样要拉。
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate

    init() { LiteralText.install() }

    var body: some Scene {
        WindowGroup {
            switch delegate.launch {
            case .ready(let services): SceneRoot(services: services, alerts: delegate.alerts)
            case .failed(let failure): UnreadableLibraryView(failure: failure) { delegate.relaunch() }.modifier(PaletteProvider())
            case .testHost: EmptyView()
            }
        }
    }
}
#endif
