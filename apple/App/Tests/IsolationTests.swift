#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import CuePad

/// 隔离模式（CUEPAD_LIBRARY_DIR）：资料库之外，偏好与窗口位置也不能落到真实的 com.sugeh.cuepad 域里。
/// 测试宿主用的就是真实域，所以这里只读真实域来确认它没被写。
@MainActor
struct IsolationTests {
    private let realKeys = ["theme", "globalShortcut", "autoSubmit", "currentProject", "NSWindow Frame main", "NSWindow Frame settings"]

    private func realDomain() -> [String: NSObject?] {
        Dictionary(uniqueKeysWithValues: realKeys.map { ($0, UserDefaults.standard.object(forKey: $0) as? NSObject) })
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cuepad-isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func 相对路径给出清楚的错误而不是崩溃() {
        do {
            _ = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": "relative/library"])
            Issue.record("相对路径应被拒绝")
        } catch let error as LibraryLocationError {
            #expect(error.localizedDescription.contains("CUEPAD_LIBRARY_DIR"))
            #expect(error.localizedDescription.contains("relative/library"))
        } catch {
            Issue.record("错误类型不对：\(error)")
        }
    }

    @Test func 没设环境变量时用真实位置与真实偏好域() throws {
        let location = try LibraryLocation.resolve(environment: [:])
        #expect(location.directory.path.hasSuffix("Application Support/CuePad/Library"))
        #expect(location.electronDatabase != nil)
        #expect(location.makeDefaults() === UserDefaults.standard)
    }

    @Test func 隔离目录下偏好落在目录内_真实域不变() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": directory.path])
        #expect(location.electronDatabase == nil)
        let before = realDomain()

        let settings = AppSettings(defaults: location.makeDefaults())
        settings.theme = .dark
        settings.currentProject = UUID()
        settings.setWindowFrame("10 20 300 200 0 0 1440 900", for: "main")

        #expect(realDomain() == before)
        let reread = AppSettings(defaults: location.makeDefaults())
        #expect(reread.theme == .dark)
        #expect(reread.currentProject == settings.currentProject)
        #expect(reread.windowFrame(for: "main") == "10 20 300 200 0 0 1440 900")
        let plist = directory.appending(path: "preferences.plist")
        await eventually { FileManager.default.fileExists(atPath: plist.path) }
        #expect(FileManager.default.fileExists(atPath: plist.path), "隔离偏好没有落在库目录里")
    }

    @Test func 启动参数覆盖已存的设置() throws {
        let temp = TempDefaults()
        let defaults = temp.defaults
        AppSettings(defaults: defaults).theme = .light

        let overridden = AppSettings(defaults: defaults, launchArguments: ["theme": "dark", "autoSubmit": "YES"])

        #expect(overridden.theme == .dark)
        #expect(overridden.autoSubmit)
        #expect(AppSettings(defaults: defaults, launchArguments: [:]).theme == .light)
    }

    @Test func 窗口位置存进设置_不写系统的自动保存域() throws {
        let temp = TempDefaults()
        let settings = AppSettings(defaults: temp.defaults, launchArguments: [:])
        let before = realDomain()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 120, width: 640, height: 480), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        let keeper = WindowFrameKeeper(window: window, name: "main", settings: settings)
        #expect(!keeper.restore(), "没有存过位置时不应恢复")

        window.setFrame(NSRect(x: 200, y: 220, width: 700, height: 500), display: false)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)

        #expect(realDomain() == before)
        let other = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        #expect(WindowFrameKeeper(window: other, name: "main", settings: settings).restore())
        #expect(other.frame.size == CGSize(width: 700, height: 500))
    }
}
#endif
