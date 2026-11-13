import CueStore
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 模型按家记，没记的是那家的默认；思考强度 nil 是默认。
nonisolated struct LaunchPreference: Codable, Equatable, Sendable {
    var agent: AgentKind
    var models: [AgentKind: ModelKey] = [:]
    var thinking: ThinkingLevel?
    var fast = false
}

@Observable
final class AppSettings {
    enum Theme: String, CaseIterable, Sendable {
        case system, light, dark
    }

    private static let draftDelay: Duration = .milliseconds(400)

    enum Key {
        static let theme = "theme"
        #if os(macOS)
        static let alerts = "alerts"
        #endif
        static let replyDrafts = "replyDrafts"
        static let sessionSeen = "sessionSeen"
        static let unreadSince = "unreadSince"
        static let lastAgent = "lastAgent"
        static let launchDefault = "launchDefault"
        static let projectLaunches = "projectLaunches"
        static let navigationPane = "navigationPane"
        static let currentProject = "currentProject"
        static let railExpanded = "railExpanded"
        static let cueOpen = "cueOpen"
        static let sounds = AlertTone.enabledKey
    }

    @ObservationIgnored let defaults: UserDefaults
    /// 打字只让读这个会话草稿的视图（它的回复框、它在列表里那一行）重算，别的行不动。
    @ObservationIgnored private var replyDrafts: [UUID: ReplyDraftSlot] = [:]
    /// 每个键都改草稿，偏好只在停手 `draftDelay` 后写一次。
    @ObservationIgnored private var draftTimer: Task<Void, Never>?

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    /// 新记灵感（菜单栏随手记）默认进它，不决定导航落点；当前项目仍从导航推出。
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }
    #if os(macOS)
    var alerts: AlertPreferences { didSet { defaults.set(alerts.stored, forKey: Key.alerts) } }
    #endif
    /// 通知的提示音与界面里的操作音一起开关（`Sound`）；手机锁屏通知的那一声由通知扩展照这个键定。
    var sounds: Bool { didSet { defaults.set(sounds, forKey: Key.sounds) } }


    /// 开新会话时上次的选择（`launchChoice`），新会话的输入框与任务的"开始"读同一份：按项目记，这个项目没选过的用最近一次选的。
    private(set) var launchDefault: LaunchPreference { didSet { defaults.set(try? JSONEncoder().encode(launchDefault), forKey: Key.launchDefault) } }
    private(set) var projectLaunches: [UUID: LaunchPreference] {
        didSet { defaults.set(try? JSONEncoder().encode(projectLaunches), forKey: Key.projectLaunches) }
    }

    func launchPreference(for project: UUID?) -> LaunchPreference { project.flatMap { projectLaunches[$0] } ?? launchDefault }

    func setLaunchPreference(for project: UUID?, _ change: (inout LaunchPreference) -> Void) {
        var preference = launchPreference(for: project)
        change(&preference)
        launchDefault = preference
        if let project { projectLaunches[project] = preference }
    }

    /// 在 `project` 里开新会话用哪家、哪个模型、多强的思考：上次选的，那台 Mac 上没有的回到它的默认。一家都不能用为 nil。
    func launchChoice(on mac: MacAgents, in project: UUID?) -> AgentModelChoice? {
        let last = launchPreference(for: project)
        guard let kind = mac.preferred(last.agent), let agent = mac.agents.first(where: { $0.kind == kind }) else { return nil }
        let model = last.models[kind].flatMap { key in agent.models.contains { $0.key == key } ? key : nil }
        return AgentModelChoice(agents: mac.agents, agent: kind, model: model, thinking: last.thinking, fast: last.fast)
    }

    var navigationPane: NavigationPane { didSet { defaults.set(navigationPane.rawValue, forKey: Key.navigationPane) } }
    /// 宽屏会话条的用户选择（只有这一份，不随主区放着什么页变）；窗口不够宽时只改变呈现，不写这个值。
    var railExpanded: Bool { didSet { defaults.set(railExpanded, forKey: Key.railExpanded) } }
    /// 窗口放不下时只改呈现，不写这个值。
    var cueOpen: Bool { didSet { defaults.set(cueOpen, forKey: Key.cueOpen) } }

    /// 按 sessionID；只留最近看的 `seenLimit` 个。
    private(set) var sessionSeen: [String: Date] { didSet { defaults.set(sessionSeen, forKey: Key.sessionSeen) } }
    /// "有新回复"从什么时候起算：第一次启动这个版本时记下，之前就停下的会话不算。
    let unreadSince: Date

    private static let seenLimit = 500

    func isUnread(_ session: SessionState) -> Bool {
        Unread.isUnread(session, seen: sessionSeen[session.sessionID], since: unreadSince)
    }

    func canMarkUnread(_ session: SessionState) -> Bool {
        Unread.canMarkUnread(session, seen: sessionSeen[session.sessionID], since: unreadSince)
    }

    func markUnread(_ session: SessionState) { markSeen(session, at: Unread.markedUnread(session)) }

    func markSeen(_ session: SessionState, at date: Date = .now) {
        var seen = sessionSeen
        seen[session.sessionID] = date
        if seen.count > Self.seenLimit {
            for (key, _) in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - Self.seenLimit) { seen[key] = nil }
        }
        sessionSeen = seen
    }

    /// 按会话记录 id；文字与批注存进本机偏好、跨退出保留，带上的卡片与图片只留在这次运行。
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

    /// 发出后传空草稿，文字一并从本机偏好里清掉。
    func setReplyDraft(_ draft: ComposerDraft, for session: UUID) {
        var rest = draft
        rest.notes = []
        slot(session).draft = rest
        setReplyNotes(draft.notes, for: session)
    }

    /// 和上次一样就不写，读批注的视图不重算。
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

    func editReplyNote(at place: ReplyNote, in session: UUID) -> ReplyNote.Edit {
        replyNotes(for: session).first { $0.marksSamePlace(as: place) }.map { ReplyNote.Edit(note: $0, fresh: false) }
            ?? ReplyNote.Edit(note: place, fresh: true)
    }

    /// 草稿里已没有它时为 nil。
    func editReplyNote(_ id: UUID, in session: UUID) -> ReplyNote.Edit? {
        replyNotes(for: session).first { $0.id == id }.map { ReplyNote.Edit(note: $0, fresh: false) }
    }

    /// `order` 是对话里回答的 id 顺序；已有的那条改字，写的时候在回复框上删掉了就不再加回来。
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

    func quote(_ preview: PreviewItem, in entry: UUID, for session: UUID) {
        let notes = replyNotes(for: session)
        guard !notes.contains(where: { $0.preview == preview.id }) else { return }
        setReplyNotes(notes + [ReplyNote(quoting: preview, in: entry)], for: session)
    }

    /// 写给这一份预览的话（全屏页里那一行）：一份一条，再写是改；清空就不留。只引用没写话的那条（`quote`）清空时留着。
    func annotate(_ preview: PreviewItem, _ text: String, in entry: UUID, for session: UUID) {
        var notes = replyNotes(for: session)
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines), index = notes.firstIndex { $0.preview == preview.id }
        if let index {
            if said.isEmpty, !notes[index].note.isEmpty { notes.remove(at: index) } else { notes[index].note = said }
        } else if !said.isEmpty {
            var note = ReplyNote(quoting: preview, in: entry)
            note.note = said
            notes.append(note)
        }
        setReplyNotes(notes, for: session)
    }

    func removeReplyNote(_ id: UUID, in session: UUID) {
        setReplyNotes(replyNotes(for: session).filter { $0.id != id }, for: session)
    }

    /// 离开前台与退出时由系统通知触发。
    func flush() {
        guard let timer = draftTimer else { return }
        timer.cancel()
        draftTimer = nil
        defaults.set(try? JSONEncoder().encode(replyDrafts.compactMapValues(\.saved)), forKey: Key.replyDrafts)
    }

    /// 清理附件文件时这些引用也算（`CueStore.removeStrayFiles`）。
    var draftTexts: [String] { replyDrafts.values.map(\.draft.text) }

    func draftPreview(for session: UUID) -> String? { replyDraft(for: session).preview }

    /// 解不出来的（存的格式变了）记一条错，原样挪到 `<键>.undecodable` 留着，之后的写入盖不到它；这一项从起点值开始。
    private static func decoded<T: Decodable>(_ type: T.Type, _ key: String, in defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppServices.log.error("设置 \(key, privacy: .public) 解不出来，原样留在 \(key, privacy: .public).undecodable：\(String(describing: error), privacy: .public)")
            defaults.set(data, forKey: key + ".undecodable")
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    /// 覆盖已存设置的启动参数，只在 Debug 构建有。
    init(defaults: UserDefaults, launchArguments: [String: Any] = DebugHooks.launchArgumentOverrides) {
        DebugHooks.dropLaunchArguments(from: defaults)
        self.defaults = defaults
        func string(_ key: String) -> String? { (launchArguments[key] as? String) ?? defaults.string(forKey: key) }
        theme = string(Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        currentProject = string(Key.currentProject).flatMap(UUID.init(uuidString:))
        #if os(macOS)
        alerts = AlertPreferences(stored: defaults.dictionary(forKey: Key.alerts))
        #endif
        sounds = defaults.object(forKey: Key.sounds) as? Bool ?? true
        // `lastAgent` 是只记哪家的旧键：没有新记录时从它起步
        launchDefault = Self.decoded(LaunchPreference.self, Key.launchDefault, in: defaults)
            ?? LaunchPreference(agent: string(Key.lastAgent).flatMap(AgentKind.init(rawValue:)) ?? .pi)
        projectLaunches = Self.decoded([UUID: LaunchPreference].self, Key.projectLaunches, in: defaults) ?? [:]
        navigationPane = string(Key.navigationPane).flatMap(NavigationPane.init(rawValue:)) ?? .projects
        railExpanded = defaults.object(forKey: Key.railExpanded) as? Bool ?? true
        cueOpen = defaults.object(forKey: Key.cueOpen) as? Bool ?? true
        sessionSeen = defaults.dictionary(forKey: Key.sessionSeen) as? [String: Date] ?? [:]
        replyDrafts = (Self.decoded([UUID: SavedDraft].self, Key.replyDrafts, in: defaults) ?? [:]).mapValues(ReplyDraftSlot.init)
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

/// 批注单独一格（`draft.notes` 恒为空）：读批注的对话不随打字重算。
@Observable
private final class ReplyDraftSlot {
    var draft = ComposerDraft()
    var notes: [ReplyNote] = []

    init() {}

    init(_ saved: SavedDraft) {
        draft.text = saved.text
        notes = saved.notes
    }

    var saved: SavedDraft? {
        draft.text.allSatisfy(\.isWhitespace) && notes.isEmpty ? nil : SavedDraft(text: draft.text, notes: notes)
    }
}

private struct SavedDraft: Codable {
    var text: String
    var notes: [ReplyNote]
}
