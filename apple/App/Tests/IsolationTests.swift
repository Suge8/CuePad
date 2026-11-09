#if os(macOS)
import CueStore
import AppKit
import Foundation
import Testing
@testable import CuePad

/// 隔离模式（CUEPAD_LIBRARY_DIR）：资料库之外，偏好与窗口位置也不能落到真实的偏好域（`AppIdentity.id`）里。
/// 测试宿主的 `UserDefaults.standard` 就是正式版的偏好域，这里连读也不读：偏好要落在库目录里那份具名的域（文件里看得到），
/// 窗口位置只存进设置，AppKit 自己写标准域的途径（窗口的自动保存名）必须是空的。
struct IsolationTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cuepad-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func 隔离目录下偏好落在目录内() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": directory.path])

        let settings = AppSettings(defaults: location.makeDefaults())
        settings.theme = .dark
        settings.currentProject = UUID()
        settings.setWindowFrame("10 20 300 200 0 0 1440 900", for: "main")

        let reread = AppSettings(defaults: location.makeDefaults())
        #expect(reread.theme == .dark)
        #expect(reread.currentProject == settings.currentProject)
        #expect(reread.windowFrame(for: "main") == "10 20 300 200 0 0 1440 900")
        let plist = directory.appending(path: "preferences.plist")
        try await eventually("隔离偏好落在库目录里") {
            let saved = NSDictionary(contentsOf: plist)
            return saved?[AppSettings.Key.theme] != nil && saved?[AppSettings.Key.currentProject] != nil
        }
    }

    @Test func 窗口位置存进设置_不写系统的自动保存域() async throws {
        let temp = TempDefaults()
        let settings = AppSettings(defaults: temp.defaults, launchArguments: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 640, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let keeper = WindowFrameKeeper(window: window, name: "main", settings: settings)

        window.setFrame(NSRect(x: 200, y: 220, width: 700, height: 500), display: false)
        await Task.yield()  // 让订阅的任务先到位，再发通知
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        try await eventually("窗口位置存进设置") { settings.windowFrame(for: "main") != nil }

        #expect(window.frameAutosaveName.isEmpty)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        _ = WindowFrameKeeper(window: other, name: "main", settings: settings)
        #expect(other.frame.size == CGSize(width: 700, height: 500))
        #expect(other.frameAutosaveName.isEmpty)
        withExtendedLifetime(keeper) {}
    }
}
#endif
