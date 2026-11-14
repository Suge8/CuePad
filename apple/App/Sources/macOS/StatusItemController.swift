#if os(macOS)
import AppKit
import QuartzCore

final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let togglePanel: @MainActor (CGRect) -> Void
    private let toggleWindow: @MainActor () -> Void

    init(togglePanel: @escaping @MainActor (CGRect) -> Void, toggleWindow: @escaping @MainActor () -> Void) {
        self.togglePanel = togglePanel
        self.toggleWindow = toggleWindow
        super.init()
        guard let button = item.button else { preconditionFailure("菜单栏图标没有按钮") }
        button.image = Self.cue
        button.toolTip = "CuePad"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 菜单栏的字随菜单栏明暗着色，不另上色：数字跟在图标右边、与图标同一条中线。
    /// 有要你管的换成会话状态标的图形：有拍板是气泡问号，只剩新回复是信封；没有就是 Cue。换图淡过去，不跳。
    func show(_ tally: CueNow.Tally) {
        guard let button = item.button else { return }
        let count = tally.needsYou
        let shown = tally.asks > 0 ? Self.asks : tally.reply > 0 ? Self.reply : Self.cue
        if button.image !== shown {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.Fade.duration
            fade.timingFunction = Motion.Fade.timing
            button.layer?.add(fade, forKey: "image")
            button.image = shown
        }
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.attributedTitle = count > 0
            ? NSAttributedString(string: "\(count)", attributes: [.font: Typography.menuBarCount])
            : NSAttributedString()
        button.setAccessibilityValue(count > 0 ? String(localized: "\(count) 件要你管") : nil)
    }

    private static let cue = image(.cue)
    private static let asks = image(.waiting)
    private static let reply = image(.replied)

    /// 20pt 的符号实高约 17pt（同系统菜单栏图标），在 22pt 高的菜单栏里上下各留一点；模板图随菜单栏明暗着色。
    private static func image(_ icon: Icon) -> NSImage {
        guard let image = icon.platformImage?.withSymbolConfiguration(.init(pointSize: Glyph.largeSize, weight: .regular)) else {
            preconditionFailure("缺少符号 \(icon)")
        }
        image.isTemplate = true
        return image
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        guard let button = item.button, let window = button.window else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel(window.frame)
        }
    }

    /// 菜单只在右键时临时挂上，否则左键也会弹菜单而不是面板。
    private func showMenu() {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: String(localized: "显示 / 隐藏"), action: #selector(toggleMainWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "退出 CuePad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleMainWindow() {
        toggleWindow()
    }
}
#endif
