#if os(macOS)
import AppKit

/// 系统的选文件面板，非模态（`begin`）：不像 `runModal` 那样把主线程关在面板的嵌套事件循环里，也不是 NSWindow sheet（见 docs/development.md）。
/// 已有一个面板开着时再要一个，只是把它带到前面。
@MainActor
enum FilePicker {
    private static var open: NSOpenPanel?

    /// 选一个文件夹；取消为 nil。
    static func folder(message: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = message
        return await show(panel).first
    }

    private static func show(_ panel: NSOpenPanel) async -> [URL] {
        if let open {
            open.makeKeyAndOrderFront(nil)
            return []
        }
        open = panel
        defer { open = nil }
        return await panel.begin() == .OK ? panel.urls : []
    }
}
#endif
