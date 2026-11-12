#if os(macOS)
import AppKit

/// 非模态（`begin`）：不像 `runModal` 那样把主线程关在面板的嵌套事件循环里，也不是 NSWindow sheet（docs/ui.md）。已有一个面板开着时再要一个，只是把它带到前面。
enum FilePicker {
    private static var open: NSOpenPanel?

    static func folder(message: LocalizedStringResource) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: message)
        return await show(panel).first
    }

    static func files() async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        return await show(panel)
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
