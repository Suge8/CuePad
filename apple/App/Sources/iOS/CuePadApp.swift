#if os(iOS)
import CueStore
import SwiftUI

@main
struct CuePadApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate
    private let launch = Launch.make()

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .ready(let services): SceneRoot(services: services, alerts: delegate.alerts)
            case .failed(let error): LaunchFailureView(message: error.localizedDescription)
            case .testHost: EmptyView()
            }
        }
    }
}

/// 进程只创建一个 `AppServices`，所有窗口共用。
@MainActor
enum Launch {
    case ready(AppServices)
    case failed(any Error)
    /// 作为单元测试宿主：不打开真实资料库。
    case testHost

    static func make() -> Launch {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .testHost }
        do {
            let location = try LibraryLocation.resolve()
            let services = AppServices(location: location, defaults: location.makeDefaults())
            services.start()
            return .ready(services)
        } catch {
            return .failed(error)
        }
    }
}

/// 配置有误（比如没有 App Group 权限）时不能带着错误的位置去读写数据：说明原因。
struct LaunchFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Text("CuePad 无法启动").font(.headline)
            Text(message).font(.callout).multilineTextAlignment(.center)
        }
        .padding()
    }
}
#endif
