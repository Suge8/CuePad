#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// "对 Cue 说"的输入条：全局快捷键（默认 ⌥⇧Space，设置里可改）在屏幕上方三分之一处唤出，再按一次或 Esc、失去焦点即收起。
/// 与菜单栏面板同一种宿主（`MenuBarPanel`：不激活应用的浮动面板）与同一种全局快捷键做法（`GlobalHotkey`，单槽，换键时先注册新的成功才放旧的）。
/// 快捷键存在设备偏好里；注册失败记成启动问题，设置里换一个。
@Observable
final class CueBar {
    /// ⌥Space 是"显示或隐藏 CuePad"的默认，这里错开一个 ⇧。
    static let defaultShortcut = "Alt+Shift+Space"
    private static let shortcutKey = "cueShortcut"
    /// 唤出处离屏幕顶边的比例。
    private static let anchorFraction: CGFloat = 0.28

    private(set) var shortcut: String
    /// 唤出的次数：输入条看它变了就聚焦。
    private(set) var opens = 0
    @ObservationIgnored private let panel = MenuBarPanel()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var hotkey: GlobalHotkey?

    init(services: AppServices, workspace: Workspace) {
        settings = services.settings
        shortcut = services.settings.defaults.string(forKey: Self.shortcutKey) ?? Self.defaultShortcut
        hotkey = GlobalHotkey(backend: services.hotkeyBackend) { [weak self] in self?.toggle() }
        panel.setContent(CueBarView(bar: self).environment(workspace).modifier(PaletteProvider()).environment(services))
        do {
            try register(shortcut)
        } catch {
            services.reportIssue(.globalShortcutUnavailable("对 Cue 说（\(ShortcutText.display(shortcut))）：\(error)"))
        }
    }

    func toggle() {
        if panel.isVisible { return hide() }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        opens += 1
        panel.show(below: CGRect(x: screen.midX, y: screen.maxY - screen.height * Self.anchorFraction, width: 0, height: 0))
    }

    func hide() { panel.hide() }

    /// 换快捷键：注册成功才写进偏好；失败时旧的照用，错误交给设置页。
    func setShortcut(_ accelerator: String) throws {
        let normalized = try register(accelerator)
        shortcut = normalized
        settings.defaults.set(normalized, forKey: Self.shortcutKey)
    }

    @discardableResult
    private func register(_ accelerator: String) throws -> String {
        guard let parsed = Shortcut(accelerator: accelerator), let normalized = parsed.accelerator else {
            throw HotkeyError.unsupportedAccelerator(accelerator)
        }
        try hotkey?.register(parsed)
        return normalized
    }

    func unregister() { hotkey?.unregister() }
}
#endif
