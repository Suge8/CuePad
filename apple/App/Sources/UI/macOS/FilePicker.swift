#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// 系统的选文件面板，非模态（`begin`）：不像 `runModal` 那样把主线程关在面板的嵌套事件循环里，也不是 NSWindow sheet（见 docs/ui.md「布局约束」）。
/// Mac 上选文件夹、选图片都经这里；已有一个面板开着时再要一个，只是把它带到前面。
enum FilePicker {
    private static var open: NSOpenPanel?

    /// 选一个文件夹；取消为 nil。
    static func folder(message: LocalizedStringResource) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "选择")
        panel.message = String(localized: message)
        return await show(panel).first
    }

    /// 选几张图片，读出文件内容（读文件不在主线程）；取消为空。
    static func images() async throws -> [Data] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        return try await read(show(panel))
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

    @concurrent private static func read(_ urls: [URL]) async throws -> [Data] {
        try urls.map { try Data(contentsOf: $0) }
    }
}
#endif
