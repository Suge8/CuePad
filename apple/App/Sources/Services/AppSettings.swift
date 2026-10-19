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

    private static let draftDelay: Duration = .milliseconds(400)

    enum Key {
        static let theme = "theme"
        #if os(macOS)
        static let globalShortcut = "globalShortcut"
        static let cueShortcut = "cueShortcut"
        static let currentProject = "currentProject"
        static let alerts = "alerts"
        #endif
        static let replyDrafts = "replyDrafts"
        static let sessionSeen = "sessionSeen"
        static let unreadSince = "unreadSince"
        static let holdSendLearned = "holdSendLearned"
        static let lastAgent = "lastAgent"
        static let showsCueSteps = "showsCueSteps"
    }

    @ObservationIgnored let defaults: UserDefaults
    /// 每个会话的草稿各是一个可观察的格子：打字只让读这个会话草稿的视图（它的回复框、它在列表里那一行）重算，别的行不动。
    @ObservationIgnored private var replyDrafts: [UUID: ReplyDraftSlot] = [:]
    /// 草稿落盘的计时：每个键都改草稿，偏好只在停手 `draftDelay` 后写一次；有未写的草稿时才有。
    @ObservationIgnored private var draftTimer: Task<Void, Never>?

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    #if os(macOS)
    /// Mac 主窗口上次打开的项目（`Workspace.page` 的唯一事实源）；iOS 的当前项目从导航路径推出，不存偏好。
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }
    /// 通知两种提示（等你、做完了）各自的开关与提示音（`AlertPreferences`）。
    var alerts: AlertPreferences { didSet { defaults.set(alerts.stored, forKey: Key.alerts) } }
    #endif

    /// 用过一次按住发送钮的菜单（马上说、放进输入框）：之后发送钮上不再提示"按住可…"。存储属性：用过的那一刻提示就收起。
    var holdSendLearned: Bool { didSet { defaults.set(holdSendLearned, forKey: Key.holdSendLearned) } }

    /// 新会话上次选的 Agent（两端的新会话在 Agent 胶囊上一选就记）：新会话默认用它（那台 Mac 上它不能用时退到第一个能用的，`MacAgents.preferred`）。
    var lastAgent: AgentKind { didSet { defaults.set(lastAgent.rawValue, forKey: Key.lastAgent) } }

    /// Cue 页对话里显示 Cue 每一轮的工具步骤（"跑了 3 步 · 建了 1 件任务"那一行与展开的清单，`CueThread.rows`）；默认不显示。只管 Cue 页，会话页每一轮的经过一直显示。
    var showsCueSteps: Bool { didSet { defaults.set(showsCueSteps, forKey: Key.showsCueSteps) } }

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

    /// 会话回复框的草稿（按会话记录 id，iOS 与 Mac 同一份）：离开会话再回来还在；文字与批注存进本机偏好、跨退出保留
    /// （`SavedDraft`，一个会话一条），带上的卡片与图片只留在这次运行。
    func replyDraft(for session: UUID) -> ComposerDraft {
        let slot = slot(session)
        var draft = slot.draft
        draft.notes = slot.notes
        return draft
    }

    /// 草稿里的批注，单独读：对话里的高亮只跟着批注变，回复框里打字时对话不重算。
    func replyNotes(for session: UUID) -> [ReplyNote] { slot(session).notes }

    private func slot(_ session: UUID) -> ReplyDraftSlot {
        if let slot = replyDrafts[session] { return slot }
        let slot = ReplyDraftSlot()
        replyDrafts[session] = slot
        return slot
    }

    /// 发出后传空草稿：文字一并从本机偏好里清掉。界面立即读到新草稿，偏好在停手后写一次（`flush`）。
    func setReplyDraft(_ draft: ComposerDraft, for session: UUID) {
        var rest = draft
        rest.notes = []
        slot(session).draft = rest
        setReplyNotes(draft.notes, for: session)
    }

    /// 只改批注（对话里的批注层、回复框上的批注一叠）；和上次一样就不写，读批注的视图不重算。落盘计时在这里排（草稿也经这里）。
    func setReplyNotes(_ notes: [ReplyNote], for session: UUID) {
        let slot = slot(session)
        if slot.notes != notes { slot.notes = notes }
        draftTimer?.cancel()
        draftTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.draftDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 在一处开始写批注（Mac 的批注层与手机的可选文本页同一套，下面两个也是）：同一处已经批注过就打开那一条，否则是新的一条。
    func editReplyNote(at place: ReplyNote, in session: UUID) -> ReplyNote.Edit {
        replyNotes(for: session).first { $0.marksSamePlace(as: place) }.map { ReplyNote.Edit(note: $0, fresh: false) }
            ?? ReplyNote.Edit(note: place, fresh: true)
    }

    /// 改已有的一条（点对话里那处高亮）；草稿里已没有它时为 nil。
    func editReplyNote(_ id: UUID, in session: UUID) -> ReplyNote.Edit? {
        replyNotes(for: session).first { $0.id == id }.map { ReplyNote.Edit(note: $0, fresh: false) }
    }

    /// 记下：新的一条按在对话里的先后排进草稿（`order` 是对话里回答的 id 顺序）；已有的那条改字（写的时候在回复框上删掉了就不再加回来）。
    func save(_ edit: ReplyNote.Edit, text: String, order: [UUID], in session: UUID) {
        var notes = replyNotes(for: session), note = edit.note
        note.note = text
        if edit.fresh {
            notes = ReplyNote.sorted(notes + [note], by: order)
        } else if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        }
        setReplyNotes(notes, for: session)
    }

    func removeReplyNote(_ id: UUID, in session: UUID) {
        setReplyNotes(replyNotes(for: session).filter { $0.id != id }, for: session)
    }

    /// 把还没写的草稿写进偏好；离开前台与退出时由系统通知触发，没有未写的草稿时什么也不做。
    func flush() {
        guard let timer = draftTimer else { return }
        timer.cancel()
        draftTimer = nil
        defaults.set(try? JSONEncoder().encode(replyDrafts.compactMapValues(\.saved)), forKey: Key.replyDrafts)
    }

    /// 会话回复框草稿的预览（会话行据此写"有草稿"，`PiRowFacts`）：回复框里没发的文字的第一行；只带了灵感或图片时说带了什么。没有草稿是 nil。
    func draftPreview(for session: UUID) -> String? { replyDraft(for: session).preview }

    /// `launchArguments`：覆盖已存设置的启动参数（只在 Debug 构建有，见 `DebugHooks.launchArgumentOverrides`）。
    init(defaults: UserDefaults, launchArguments: [String: Any] = DebugHooks.launchArgumentOverrides) {
        DebugHooks.dropLaunchArguments(from: defaults)
        self.defaults = defaults
        func string(_ key: String) -> String? { (launchArguments[key] as? String) ?? defaults.string(forKey: key) }
        theme = string(Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        #if os(macOS)
        currentProject = string(Key.currentProject).flatMap(UUID.init(uuidString:))
        alerts = AlertPreferences(stored: defaults.dictionary(forKey: Key.alerts))
        #endif
        holdSendLearned = defaults.bool(forKey: Key.holdSendLearned)
        lastAgent = string(Key.lastAgent).flatMap(AgentKind.init(rawValue:)) ?? .pi
        showsCueSteps = string(Key.showsCueSteps).map { ($0 as NSString).boolValue } ?? false
        sessionSeen = defaults.dictionary(forKey: Key.sessionSeen) as? [String: Date] ?? [:]
        replyDrafts = (defaults.data(forKey: Key.replyDrafts).flatMap { try? JSONDecoder().decode([UUID: SavedDraft].self, from: $0) } ?? [:])
            .mapValues(ReplyDraftSlot.init)
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

/// 一个会话回复框的草稿（`AppSettings.replyDraft`）。批注单独一格（`draft.notes` 恒为空）：读批注的对话不随打字重算。
@Observable
private final class ReplyDraftSlot {
    var draft = ComposerDraft()
    var notes: [ReplyNote] = []

    init() {}

    init(_ saved: SavedDraft) {
        draft.text = saved.text
        notes = saved.notes
    }

    /// 存进偏好的那份；空草稿不存。
    var saved: SavedDraft? {
        draft.text.allSatisfy(\.isWhitespace) && notes.isEmpty ? nil : SavedDraft(text: draft.text, notes: notes)
    }
}

/// 偏好里一个会话的草稿：跨退出保留的只有文字与批注。
private struct SavedDraft: Codable {
    var text: String
    var notes: [ReplyNote]
}
