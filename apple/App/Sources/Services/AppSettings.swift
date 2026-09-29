import Foundation
import Observation

/// 设备本地偏好，存 UserDefaults，不进同步库。
@MainActor @Observable
final class AppSettings {
    enum Theme: String, CaseIterable, Sendable {
        case system, light, dark
    }

    static let defaultGlobalShortcut = "Alt+Space"

    private enum Key {
        static let theme = "theme"
        static let globalShortcut = "globalShortcut"
        static let autoSubmit = "autoSubmit"
        static let currentProject = "currentProject"
        static let piExtensionDeclinedVersion = "piExtensionDeclinedVersion"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// W3C code 形式的加速键（如 `Alt+Space`），与 Electron 版存储格式一致。
    var globalShortcut: String { didSet { defaults.set(globalShortcut, forKey: Key.globalShortcut) } }
    /// 通用投送后是否补发回车。
    var autoSubmit: Bool { didSet { defaults.set(autoSubmit, forKey: Key.autoSubmit) } }
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }

    /// 用户拒绝安装的 Pi 扩展版本；随包版本更新后会再次征求同意。
    var piExtensionDeclinedVersion: Int? {
        get { defaults.object(forKey: Key.piExtensionDeclinedVersion) as? Int }
        set { defaults.set(newValue, forKey: Key.piExtensionDeclinedVersion) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        theme = defaults.string(forKey: Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        globalShortcut = defaults.string(forKey: Key.globalShortcut) ?? Self.defaultGlobalShortcut
        autoSubmit = defaults.bool(forKey: Key.autoSubmit)
        currentProject = defaults.string(forKey: Key.currentProject).flatMap(UUID.init(uuidString:))
    }

    /// 旧版设置只作初始值：用户在新版里设置过的项不覆盖。
    func adoptLegacy(theme: Theme?, globalShortcut: String?) {
        if let theme, defaults.object(forKey: Key.theme) == nil { self.theme = theme }
        if let globalShortcut, defaults.object(forKey: Key.globalShortcut) == nil { self.globalShortcut = globalShortcut }
    }
}
