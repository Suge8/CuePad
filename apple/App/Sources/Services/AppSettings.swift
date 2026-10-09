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
        static let currentProject = "currentProject"
        static let piExtensionDeclined = "piExtensionDeclined"
        static let commandLineToolPrompted = "commandLineToolPrompted"
        static let replyTexts = "replyTexts"
        static let sessionSeen = "sessionSeen"
        static let unreadSince = "unreadSince"
        static let agentProject = "agentProject"
        static let holdSendLearned = "holdSendLearned"
    }

    private static let frameKeyPrefix = "NSWindow Frame " // 与系统窗口自动保存同名同格式，沿用已存的位置

    @ObservationIgnored private let defaults: UserDefaults
    /// 每个会话的草稿各是一个可观察的格子：打字只让读这个会话草稿的视图（它的回复框、它在列表里那一行）重算，别的行不动。
    @ObservationIgnored private var replyDrafts: [UUID: ReplyDraftSlot] = [:]

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// W3C code 形式的加速键（如 `Alt+Space`）。
    var globalShortcut: String { didSet { defaults.set(globalShortcut, forKey: Key.globalShortcut) } }
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

    /// 用过一次按住发送钮的菜单（马上说、放进输入框）：之后发送钮上不再提示"按住可…"。存储属性：用过的那一刻提示就收起。
    var holdSendLearned: Bool { didSet { defaults.set(holdSendLearned, forKey: Key.holdSendLearned) } }

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
        slot(session).draft
    }

    private func slot(_ session: UUID) -> ReplyDraftSlot {
        if let slot = replyDrafts[session] { return slot }
        let slot = ReplyDraftSlot()
        replyDrafts[session] = slot
        return slot
    }

    /// 发出后传空草稿：文字一并从本机偏好里清掉。
    func setReplyDraft(_ draft: ComposerDraft, for session: UUID) {
        slot(session).draft = draft
        defaults.set(replyDrafts.compactMapValues { $0.draft.text.allSatisfy(\.isWhitespace) ? nil : $0.draft.text }
            .reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }, forKey: Key.replyTexts)
    }

    /// 会话行上的草稿（`PiRowLine.draft`）：回复框里没发的文字的第一行；只带了灵感或图片时说带了什么。没有草稿是 nil。
    func draftPreview(for session: UUID) -> String? {
        let draft = replyDraft(for: session)
        if let line = draft.text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return line
        }
        let parts = [
            draft.attachments.isEmpty ? nil : "\(draft.attachments.count) 条灵感",
            draft.images.isEmpty ? nil : "\(draft.images.count) 张图片",
        ].compactMap { $0 }
        return parts.isEmpty ? nil : "带了 " + parts.joined(separator: "、")
    }

    init(defaults: UserDefaults, launchArguments: [String: Any] = AppSettings.launchArgumentOverrides) {
        #if !DEBUG
        if defaults === UserDefaults.standard { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        #endif
        self.defaults = defaults
        func string(_ key: String) -> String? { (launchArguments[key] as? String) ?? defaults.string(forKey: key) }
        theme = string(Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        globalShortcut = string(Key.globalShortcut) ?? Self.defaultGlobalShortcut
        currentProject = string(Key.currentProject).flatMap(UUID.init(uuidString:))
        piExtensionDeclined = launchArguments[Key.piExtensionDeclined].map(Self.isTrue) ?? defaults.bool(forKey: Key.piExtensionDeclined)
        holdSendLearned = defaults.bool(forKey: Key.holdSendLearned)
        sessionSeen = defaults.dictionary(forKey: Key.sessionSeen) as? [String: Date] ?? [:]
        replyDrafts = (defaults.dictionary(forKey: Key.replyTexts) as? [String: String] ?? [:]).reduce(into: [:]) { drafts, entry in
            if let id = UUID(uuidString: entry.key) { drafts[id] = ReplyDraftSlot(ComposerDraft(text: entry.value)) }
        }
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

/// 一个会话回复框的草稿（`AppSettings.replyDraft`）。
@MainActor @Observable
private final class ReplyDraftSlot {
    var draft: ComposerDraft

    init(_ draft: ComposerDraft = ComposerDraft()) { self.draft = draft }
}
