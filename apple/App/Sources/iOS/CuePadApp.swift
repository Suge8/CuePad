#if os(iOS)
import CueStore
import SwiftUI

@main
struct CuePadApp: App {
    @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var delegate
    @State private var launch = Launch.make()

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .ready(let services): SceneRoot(services: services, alerts: delegate.alerts)
            case .failed(let failure): UnreadableLibraryView(failure: failure) { launch = Launch.make() }.modifier(PaletteProvider())
            case .testHost: EmptyView()
            }
        }
    }
}

/// 进程只创建一个 `AppServices`，所有窗口共用。资料库打不开时不终止进程：失败页给原因、重试与诊断。
@MainActor
enum Launch {
    case ready(AppServices)
    case failed(LibraryFailure)
    /// 作为单元测试宿主：不打开真实资料库。
    case testHost

    static func make() -> Launch {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return .testHost }
        do {
            return open(try LibraryLocation.resolve())
        } catch {
            // 位置本身解析不出来（比如没有 App Group 权限）：没有库文件可读，失败里的版本为空
            return .failed(LibraryFailure(error, location: nil))
        }
    }

    static func open(_ location: LibraryLocation) -> Launch {
        do {
            let services = try AppServices(location: location, defaults: location.makeDefaults(), sync: .iCloud)
            services.start()
            return .ready(services)
        } catch {
            return .failed(LibraryFailure(error, location: location))
        }
    }
}
#endif
