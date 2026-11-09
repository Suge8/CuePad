import CueStore
import Foundation

nonisolated enum CaptureCopy {
    #if os(macOS)
    static var prompt: String { String(localized: "记下灵感（⌘↩）") }

    static func placeholder(to destination: String) -> String { String(localized: "记下灵感 → \(destination)（⌘↩）") }
    #else
    static var prompt: String { String(localized: "记下灵感") }

    static func placeholder(to destination: String) -> String { String(localized: "记下灵感 → \(destination)") }
    #endif

    static func saved(to destination: String) -> String { String(localized: "已记到 \(destination)") }
}

struct CaptureDraft {
    var text: String
    var files: [DraftFile]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }

    /// 项目已失效时 `Workspace` 回落到默认项目，提示照实写。
    func save(in project: UUID, workspace: Workspace) async throws {
        let store = workspace.services.store
        let card = try await workspace.createCard(body: StoredBody.make(text: text, files: files), in: project)
        let destination = try await store.project(card.projectID)?.shownName ?? ""
        workspace.say(Dotted(CaptureCopy.saved(to: destination)), link: .project(card.projectID))
    }
}

extension Workspace {
    func saveReply(_ text: String, of session: PiSessionState) async throws {
        try await CaptureDraft(text: text, files: []).save(in: session.projectID ?? Project.defaultID, workspace: self)
    }
}
