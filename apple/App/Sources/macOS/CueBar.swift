#if os(macOS)
import AppKit
import Observation
import SwiftUI

/// "对 Cue 说"的输入条：全局快捷键（默认 ⌥⇧Space，设置里可改）在屏幕上方三分之一处唤出，再按一次或 Esc、失去焦点即收起。
/// 与菜单栏面板同一种宿主（`MenuBarPanel`：不激活应用的浮动面板）与同一种全局快捷键做法（`GlobalHotkey`，单槽，换键时先注册新的成功才放旧的）。
/// 快捷键存在设备偏好里；注册失败记成启动问题，设置里换一个。
@Observable
final class CueBar {
    /// 唤出处离屏幕顶边的比例。
    private static let anchorFraction: CGFloat = 0.28

    /// 唤出的次数：输入条看它变了就聚焦。
    private(set) var opens = 0
    @ObservationIgnored private let panel = MenuBarPanel()
    @ObservationIgnored private let services: AppServices
    /// ⌥Space 是"显示或隐藏 CuePad"的默认，这里错开一个 ⇧。
    @ObservationIgnored private(set) lazy var hotkey = GlobalHotkey(
        label: "对 Cue 说", key: AppSettings.Key.cueShortcut, defaultAccelerator: "Alt+Shift+Space", defaults: services.settings.defaults,
        backend: services.hotkeyBackend
    ) { [weak self] in self?.toggle() }

    init(services: AppServices, workspace: Workspace) {
        self.services = services
        panel.setContent(CueBarView(bar: self).environment(workspace).modifier(PaletteProvider()).environment(services))
        services.register(hotkey)
    }

    func toggle() {
        if panel.isVisible { return hide() }
        guard let screen = NSScreen.main?.visibleFrame else { return }
        opens += 1
        panel.show(below: CGRect(x: screen.midX, y: screen.maxY - screen.height * Self.anchorFraction, width: 0, height: 0))
    }

    func hide() { panel.hide() }
}
#endif
