#if os(macOS)
import AppKit

@main
enum MacMain {
    static func main() {
        let app = CuePadApplication.shared
        // 作为单元测试宿主时不启动壳层，避免注册真实全局热键与菜单栏图标。
        let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // 测试宿主与脚本截图在后台跑：不进程序坞、不抢前台与键盘。用 accessory 而不是 prohibited：测试要显示窗口，量交互的基准要自己激活
        if hostsTests || DebugHooks.staysInBackground { app.setActivationPolicy(.accessory) }
        let delegate = hostsTests ? nil : AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
