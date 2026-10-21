#if os(macOS)
import AppKit

@main
enum MacMain {
    static func main() {
        LiteralText.install()
        let app = NSApplication.shared
        // 作为单元测试宿主时不启动壳层，避免注册真实全局热键与菜单栏图标。
        let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let delegate = hostsTests ? nil : AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
