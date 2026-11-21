import CueStore
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

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
        static let connectedAgents = "connectedAgents"
        #endif
        static let replyDrafts = "replyDrafts"
        static let launchDefault = "launchDefault"
        static let projectLaunches = "projectLaunches"
        static let navigationPane = "navigationPane"
        static let currentProject = "currentProject"
        static let railExpanded = "railExpanded"
        static let railOpenProjects = "railOpenProjects"
        static let cueOpen = "cueOpen"
        static let cueLeft = "cueLeft"
        static let sounds = AlertTone.enabledKey
    }

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var replyDrafts: [UUID: ReplyDraftSlot] = [:]
    @ObservationIgnored private var draftTimer: Task<Void, Never>?

    var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: Key.theme) } }
    var currentProject: UUID? {
        didSet { defaults.set(currentProject?.uuidString, forKey: Key.currentProject) }
    }
    #if os(macOS)
    var alerts: AlertPreferences { didSet { defaults.set(alerts.stored, forKey: Key.alerts) } }
    var connectedAgents: Set<AgentKind> { didSet { defaults.set(connectedAgents.map(\.rawValue).sorted(), forKey: Key.connectedAgents) } }
    #endif
    var sounds: Bool { didSet { defaults.set(sounds, forKey: Key.sounds) } }


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

    func launchChoice(on mac: MacAgents, in project: UUID?) -> AgentModelChoice? {
        let last = launchPreference(for: project)
        guard let kind = mac.preferred(last.agent), let agent = mac.agents.first(where: { $0.kind == kind }) else { return nil }
        let model = last.models[kind].flatMap { key in agent.models.contains { $0.key == key } ? key : nil }
        return AgentModelChoice(agents: mac.agents, agent: kind, model: model, thinking: last.thinking, fast: last.fast)
    }

    var navigationPane: NavigationPane { didSet { defaults.set(navigationPane.rawValue, forKey: Key.navigationPane) } }
    var railExpanded: Bool { didSet { defaults.set(railExpanded, forKey: Key.railExpanded) } }
    var railOpenProjects: Set<UUID> { didSet { defaults.set(railOpenProjects.map(\.uuidString), forKey: Key.railOpenProjects) } }
    var cueOpen: Bool { didSet { defaults.set(cueOpen, forKey: Key.cueOpen) } }
    @ObservationIgnored var cueLeft: Date? { didSet { defaults.set(cueLeft, forKey: Key.cueLeft) } }

    func replyDraft(for session: UUID) -> ComposerDraft {
        let slot = slot(session)
        var draft = slot.draft
        draft.notes = slot.notes
        return draft
    }

    func replyNotes(for session: UUID) -> [ReplyNote] { slot(session).notes }

    private func slot(_ session: UUID) -> ReplyDraftSlot {
        if let slot = replyDrafts[session] { return slot }
        let slot = ReplyDraftSlot()
        replyDrafts[session] = slot
        return slot
    }

    func setReplyDraft(_ draft: ComposerDraft, for session: UUID) {
        var rest = draft
        rest.notes = []
        slot(session).draft = rest
        setReplyNotes(draft.notes, for: session)
    }

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

    func editReplyNote(_ id: UUID, in session: UUID) -> ReplyNote.Edit? {
        replyNotes(for: session).first { $0.id == id }.map { ReplyNote.Edit(note: $0, fresh: false) }
    }

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

    func quote(_ element: ReplyNote.Element, for session: UUID) {
        let notes = replyNotes(for: session)
        guard !notes.contains(where: { $0.element?.page == element.page && $0.element?.selector == element.selector }) else { return }
        setReplyNotes(notes + [ReplyNote(picking: element)], for: session)
    }

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

    func flush() {
        guard let timer = draftTimer else { return }
        timer.cancel()
        draftTimer = nil
        defaults.set(try? JSONEncoder().encode(replyDrafts.compactMapValues(\.saved)), forKey: Key.replyDrafts)
    }

    var draftTexts: [String] { replyDrafts.values.map(\.draft.text) }

    func draftPreview(for session: UUID) -> String? { replyDraft(for: session).preview }

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

    init(defaults: UserDefaults, launchArguments: [String: Any] = DebugHooks.launchArgumentOverrides) {
        DebugHooks.dropLaunchArguments(from: defaults)
        self.defaults = defaults
        func string(_ key: String) -> String? { (launchArguments[key] as? String) ?? defaults.string(forKey: key) }
        theme = string(Key.theme).flatMap(Theme.init(rawValue:)) ?? .system
        currentProject = string(Key.currentProject).flatMap(UUID.init(uuidString:))
        #if os(macOS)
        alerts = AlertPreferences(stored: defaults.dictionary(forKey: Key.alerts))
        connectedAgents = Set((defaults.stringArray(forKey: Key.connectedAgents) ?? []).compactMap(AgentKind.init(rawValue:)))
        #endif
        sounds = defaults.object(forKey: Key.sounds) as? Bool ?? true
        launchDefault = Self.decoded(LaunchPreference.self, Key.launchDefault, in: defaults) ?? LaunchPreference(agent: .pi)
        projectLaunches = Self.decoded([UUID: LaunchPreference].self, Key.projectLaunches, in: defaults) ?? [:]
        navigationPane = string(Key.navigationPane).flatMap(NavigationPane.init(rawValue:)) ?? .projects
        railExpanded = defaults.object(forKey: Key.railExpanded) as? Bool ?? true
        railOpenProjects = Set((defaults.stringArray(forKey: Key.railOpenProjects) ?? []).compactMap(UUID.init(uuidString:)))
        cueOpen = defaults.object(forKey: Key.cueOpen) as? Bool ?? true
        cueLeft = defaults.object(forKey: Key.cueLeft) as? Date
        replyDrafts = (Self.decoded([UUID: SavedDraft].self, Key.replyDrafts, in: defaults) ?? [:]).mapValues(ReplyDraftSlot.init)
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
