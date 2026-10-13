import CueStore
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 设备本地偏好，存 UserDefaults，不进同步库。
@Observable
final class AppSettings {
    enum Theme: String, CaseIterable, Sendable {
        case system, light, dark
    }

    static let defaultGlobalShortcut = "Alt+Space"
    private static let draftDelay: Duration = .milliseconds(400)

    enum Key {
        static let theme = "theme"
        static let globalShortcut = "globalShortcut"
        #if os(macOS)
        static let currentProject = "currentProject"
        #endif
        static let replyTexts = "replyTexts"
        static let sessionSeen = "sessionSeen"
        static let unreadSince = "unreadSince"
        static let agentProject = "agentProject"
        static let holdSendLearned = "holdSendLearned"
    }

    @ObservationIgnored let defaults: UserDefaults
    /// 每个会话的草稿各是一个可观察的格子：打字只让读这个会话草稿的视图（它的回复框、它在列表里那一行）重算，别的行不动。
    @ObservationIgnored private var replyDrafts: [UUID: ReplyDraftSlot] = [:]
    /// 草稿落盘的计时：每个键都改草稿，偏好只在停手 `draftDelay` 后写一次；有未写的草稿时才有。
    @ObservationIgnored private var draftTimer: Task<Void, Never>?

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// W3C code 形式的加速键（如 `Alt+Space`）。
    var globalShortcut: String { didSet { defaults.set(globalShortcut, forKey: Key.globalShortcut) } }
    #if os(macOS)
    /// Mac 主窗口上次打开的项目（`Workspace.page` 的唯一事实源）；iOS 的当前项目从导航路径推出，不存偏好。
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }
    #endif

    /// 启动参数覆盖已存的设置（只在 Debug 构建，见 `DebugHooks.launchArgumentOverrides`）。
    static var launchArgumentOverrides: [String: Any] { DebugHooks.launchArgumentOverrides }

    /// 用过一次按住发送钮的菜单（马上说、放进输入框）：之后发送钮上不再提示"按住可…"。存储属性：用过的那一刻提示就收起。
    var holdSendLearned: Bool { didSet { defaults.set(holdSendLearned, forKey: Key.holdSendLearned) } }

    /// iOS Agent 页上次选的项目筛选；nil 是全部。存储属性：选的那一刻页面就跟着变。
    var agentProject: UUID? { didSet { defaults.set(agentProject?.uuidString, forKey: Key.agentProject) } }

    /// 本机最后一次看每个 Pi 会话的时间（按 sessionID），判断"有新回复"（`PiUnread`）；只留最近看的 `seenLimit` 个。
    private(set) var sessionSeen: [String: Date] { didSet { defaults.set(sessionSeen, forKey: Key.sessionSeen) } }
    /// "有新回复"从什么时候起算：第一次启动这个版本时记下，之前就停下的会话不算。
    let unreadSince: Date

    private static let seenLimit = 500

    func isUnread(_ session: PiSessionState) -> Bool {
        PiUnread.isUnread(session, seen: sessionSeen[session.sessionID], since: unreadSince)
    }

    func canMarkUnread(_ session: PiSessionState) -> Bool {
        PiUnread.canMarkUnread(session, seen: sessionSeen[session.sessionID], since: unreadSince)
    }

    /// 标为未读：看过的时刻回拨到它停下之前（规则在 `PiUnread`）。
    func markUnread(_ session: PiSessionState) { markSeen(session, at: PiUnread.markedUnread(session)) }

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

    /// 发出后传空草稿：文字一并从本机偏好里清掉。界面立即读到新草稿，偏好在停手后写一次（`flush`）。
    func setReplyDraft(_ draft: ComposerDraft, for session: UUID) {
        slot(session).draft = draft
        draftTimer?.cancel()
        draftTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.draftDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 把还没写的草稿文字写进偏好；离开前台与退出时由系统通知触发，没有未写的草稿时什么也不做。
    func flush() {
        guard let timer = draftTimer else { return }
        timer.cancel()
        draftTimer = nil
        defaults.set(replyDrafts.compactMapValues { $0.draft.text.allSatisfy(\.isWhitespace) ? nil : $0.draft.text }
            .reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }, forKey: Key.replyTexts)
    }

    /// 会话行上的草稿（`PiRowLine.draft`）：回复框里没发的文字的第一行；只带了灵感或图片时说带了什么。没有草稿是 nil。
    func draftPreview(for session: UUID) -> String? { replyDraft(for: session).preview }

    init(defaults: UserDefaults, launchArguments: [String: Any] = AppSettings.launchArgumentOverrides) {
        #if !DEBUG
        if defaults === UserDefaults.standard { defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain) }
        #endif
        self.defaults = defaults
        func string(_ key: String) -> String? { (launchArguments[key] as? String) ?? defaults.string(forKey: key) }
        theme = string(Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        globalShortcut = string(Key.globalShortcut) ?? Self.defaultGlobalShortcut
        #if os(macOS)
        currentProject = string(Key.currentProject).flatMap(UUID.init(uuidString:))
        #endif
        holdSendLearned = defaults.bool(forKey: Key.holdSendLearned)
        agentProject = defaults.string(forKey: Key.agentProject).flatMap(UUID.init(uuidString:))
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
        for name in [Self.leavingForeground, Self.terminating] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
    }

    #if canImport(UIKit)
    private static let leavingForeground = UIApplication.willResignActiveNotification
    private static let terminating = UIApplication.willTerminateNotification
    #else
    private static let leavingForeground = NSApplication.willResignActiveNotification
    private static let terminating = NSApplication.willTerminateNotification
    #endif
}

/// 一个会话回复框的草稿（`AppSettings.replyDraft`）。
@Observable
private final class ReplyDraftSlot {
    var draft: ComposerDraft

    init(_ draft: ComposerDraft = ComposerDraft()) { self.draft = draft }
}
