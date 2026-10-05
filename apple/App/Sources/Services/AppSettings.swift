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
        static let piExtensionDeclined = "piExtensionDeclined"
        static let commandLineToolPrompted = "commandLineToolPrompted"
        static let piTerminal = "piTerminal"
    }

    private static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置

    @ObservationIgnored private let defaults: UserDefaults

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// W3C code 形式的加速键（如 `Alt+Space`），与 Electron 版存储格式一致。
    var globalShortcut: String { didSet { defaults.set(globalShortcut, forKey: Key.globalShortcut) } }
    /// 通用投送后是否补发回车。
    var autoSubmit: Bool { didSet { defaults.set(autoSubmit, forKey: Key.autoSubmit) } }
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }

    /// 继续会话、开新会话时在哪个终端里打开（Mac）；可选的是本机装了的，见 `PiTerminalApp.installed`。
    var piTerminal: PiTerminalApp { didSet { defaults.set(piTerminal.rawValue, forKey: Key.piTerminal) } }

    /// 用户拒绝过首次安装 Pi 扩展：之后不再询问、不安装。存储属性：询问卡片据此在点"不用了"的同一刻收起。
    var piExtensionDeclined: Bool { didSet { defaults.set(piExtensionDeclined, forKey: Key.piExtensionDeclined) } }

    /// 启动参数（`-theme dark` 这类）覆盖已存的设置，只在 DEBUG 构建生效：视觉验收要用，发布版不能被命令行参数改设置。
    /// 标准偏好域自带这层覆盖；隔离模式的套件读不到，所以显式传入。
    static var launchArgumentOverrides: [String: Any] {
        #if DEBUG
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        #else
        [:]
        #endif
    }

    /// 是否已经提示过安装命令行工具（只在首次启动提示一次）。
    var commandLineToolPrompted: Bool {
        get { defaults.bool(forKey: Key.commandLineToolPrompted) }
        set { defaults.set(newValue, forKey: Key.commandLineToolPrompted) }
    }

    init(defaults: UserDefaults, launchArguments: [String: Any] = AppSettings.launchArgumentOverrides) {
        #if !DEBUG
        if defaults === UserDefaults.standard { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        #endif
        self.defaults = defaults
        func string(_ key: String) -> String? { (launchArguments[key] as? String) ?? defaults.string(forKey: key) }
        theme = string(Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        globalShortcut = string(Key.globalShortcut) ?? Self.defaultGlobalShortcut
        autoSubmit = launchArguments[Key.autoSubmit].map(Self.isTrue) ?? defaults.bool(forKey: Key.autoSubmit)
        currentProject = string(Key.currentProject).flatMap(UUID.init(uuidString:))
        piExtensionDeclined = launchArguments[Key.piExtensionDeclined].map(Self.isTrue) ?? defaults.bool(forKey: Key.piExtensionDeclined)
        piTerminal = string(Key.piTerminal).flatMap(PiTerminalApp.init(rawValue:)) ?? .terminal
    }

    private static func isTrue(_ value: Any) -> Bool {
        if let flag = value as? Bool { return flag }
        return ["yes", "true", "1"].contains(String(describing: value).lowercased())
    }

    /// 窗口位置（`NSWindow.frameDescriptor` 字符串）：设备本地偏好，与其他偏好同处一个存储。
    func windowFrame(for name: String) -> String? {
        defaults.string(forKey: Self.frameKeyPrefix + name)
    }

    func setWindowFrame(_ descriptor: String, for name: String) {
        defaults.set(descriptor, forKey: Self.frameKeyPrefix + name)
    }

    /// 旧版设置只作初始值：用户在新版里设置过的项不覆盖。
    func adoptLegacy(theme: Theme?, globalShortcut: String?) {
        if let theme, defaults.object(forKey: Key.theme) == nil { self.theme = theme }
        if let globalShortcut, defaults.object(forKey: Key.globalShortcut) == nil { self.globalShortcut = globalShortcut }
    }
}
