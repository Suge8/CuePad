#if os(macOS)
import AppKit
import Observation
import SwiftUI

@Observable
final class CueBar {
    private static let anchorFraction: CGFloat = 0.28

    private(set) var opens = 0
    @ObservationIgnored private let panel = MenuBarPanel()
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private(set) lazy var hotkey = GlobalHotkey(
        label: String(localized: "对 Cue 说"), slot: .cue, settings: services.settings, backend: services.hotkeyBackend
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
