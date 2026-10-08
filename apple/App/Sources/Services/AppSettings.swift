import CueStore
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
        static let replyTexts = "replyTexts"
        static let sessionSeen = "sessionSeen"
        static let unreadSince = "unreadSince"
        static let agentProject = "agentProject"
    }

    private static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置

    @ObservationIgnored private let defaults: UserDefaults
    private var replyDrafts: [UUID: ComposerDraft] = [:]

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// W3C code 形式的加速键（如 `Alt+Space`）。
    var globalShortcut: String { didSet { defaults.set(globalShortcut, forKey: Key.globalShortcut) } }
    /// 通用投送后是否补发回车。
    var autoSubmit: Bool { didSet { defaults.set(autoSubmit, forKey: Key.autoSubmit) } }
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }

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

    /// iOS Agent 页上次选的项目筛选；nil 是全部。
    var agentProject: UUID? {
        get { defaults.string(forKey: Key.agentProject).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Key.agentProject) }
    }

    /// 本机最后一次看每个 Pi 会话的时间（按 sessionID），判断"有新回复"（`PiUnread`）；只留最近看的 `seenLimit` 个。
    private(set) var sessionSeen: [String: Date] { didSet { defaults.set(sessionSeen, forKey: Key.sessionSeen) } }
    /// "有新回复"从什么时候起算：第一次启动这个版本时记下，之前就停下的会话不算。
    let unreadSince: Date

    private static let seenLimit = 500

    func isUnread(_ session: PiSessionState) -> Bool {
        PiUnread.isUnread(session, seen: sessionSeen[session.sessionID], since: unreadSince)
    }

    func markSeen(_ session: PiSessionState, at date: Date = .now) {
        var seen = sessionSeen
        seen[session.sessionID] = date
        if seen.count > Self.seenLimit {
            for (key, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - Self.seenLimit) { seen[key] = nil }
        }
        sessionSeen = seen
    }

    /// 会话回复框的草稿（按会话记录 id，iOS 与 Mac 同一份）：离开会话再回来还在；文字另存本机偏好、跨退出保留，
    /// 带上的卡片与图片只留在这次运行。
    func replyDraft(for session: UUID) -> ComposerDraft {
        replyDrafts[session] ?? ComposerDraft(text: (defaults.dictionary(forKey: Key.replyTexts) as? [String: String])?[session.uuidString] ?? "")
    }

    /// 发出后传空草稿：文字一并从本机偏好里清掉。
    func setReplyDraft(_ draft: ComposerDraft, for session: UUID) {
        replyDrafts[session] = draft
        var texts = defaults.dictionary(forKey: Key.replyTexts) as? [String: String] ?? [:]
        texts[session.uuidString] = draft.text.allSatisfy(\.isWhitespace) ? nil : draft.text
        defaults.set(texts, forKey: Key.replyTexts)
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
        sessionSeen = defaults.dictionary(forKey: Key.sessionSeen) as? [String: Date] ?? [:]
        // 启动参数（演示截图）可以把起点挪到很早，让演示库里停下的会话都算有新回复
        if let seconds = launchArguments[Key.unreadSince].flatMap({ Double(String(describing: $0)) }) {
            unreadSince = Date(timeIntervalSince1970: seconds)
        } else if let since = defaults.object(forKey: Key.unreadSince) as? Date {
            unreadSince = since
        } else {
            unreadSince = .now
            defaults.set(unreadSince, forKey: Key.unreadSince)
        }
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
}
