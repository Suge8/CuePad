import CueStore
import CueText
import Foundation

/// 随手记的文案（iOS 底部输入框、Mac 菜单栏面板共用）：记下的都是灵感；占位写明落到哪，记下后的提示写明落点，点它去那里。
nonisolated enum CaptureCopy {
    static let inbox = "未归档"

    static func destination(_ project: Project?) -> String { project?.name ?? inbox }

    static func placeholder(to destination: String) -> String { "记下灵感 → \(destination)" }

    static func saved(to destination: String) -> String { "已记到 \(destination)" }
}

/// 随手记的草稿：一段文字加若干图片，存成一条灵感（文字在前，图片按顺序各占一行）。要做的事随后点"要做"。
struct CaptureDraft {
    var text: String
    var images: [Data]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    /// 存下并提示实际的落点（点提示去那里）；项目已失效时 `Workspace` 回落到未归档，提示照实写。
    func save(in project: UUID?, workspace: Workspace) async throws {
        let store = workspace.services.store
        let files = store.files
        let body = StoredBody.make(text: text, imageHashes: try images.map { try files.store($0) })
        let card = try await workspace.createCard(body: body, in: project)
        let destination = try await card.projectID.asyncFlatMap { try await store.project($0) }
        workspace.say(CaptureCopy.saved(to: CaptureCopy.destination(destination)), link: .project(card.projectID))
    }
}

extension Workspace {
    /// Pi 的一条回答存为灵感：进该会话所属项目，没有项目进未归档；提示落点，点它过去。
    func saveReply(_ text: String, of session: PiSessionState) async throws {
        try await CaptureDraft(text: text, images: []).save(in: session.projectID, workspace: self)
    }
}

extension Optional {
    fileprivate func asyncFlatMap<T>(_ transform: (Wrapped) async throws -> T?) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
