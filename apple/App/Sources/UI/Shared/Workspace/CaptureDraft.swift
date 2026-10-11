import CueStore
import Foundation

/// 随手记的文案（iOS 浮起的输入框、Mac 底部输入栏与菜单栏面板共用）：记下的都是灵感；落点写在头部的胶囊上，占位只写"记下灵感"，
/// 只有 Mac 底部输入栏收成一行（没有胶囊）时占位带上落点；记下后的提示写明落点，点它去那里。
/// Mac 上 ↩ 是换行、⌘↩ 才记下，占位里写明；手机上右下的钮就是记下，不写。
nonisolated enum CaptureCopy {
    static let inbox = "未分类"
    static var prompt: String { "记下灵感" + keyHint }

    static func destination(_ project: Project?) -> String { project?.name ?? inbox }

    static func placeholder(to destination: String) -> String { "记下灵感 → \(destination)" + keyHint }

    private static var keyHint: String {
        #if os(macOS)
        "（⌘↩ 记下）"
        #else
        ""
        #endif
    }

    static func saved(to destination: String) -> String { "已记到 \(destination)" }
}

/// 随手记的草稿：一段文字加若干图片，存成一条灵感（文字在前，图片按顺序各占一行）。要做的事随后"设为任务"。
struct CaptureDraft {
    var text: String
    var images: [Data]

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty }

    /// 存下并提示实际的落点（点提示去那里）；项目已失效时 `Workspace` 回落到未分类，提示照实写。
    func save(in project: UUID?, workspace: Workspace) async throws {
        let store = workspace.services.store
        let files = store.files
        let body = StoredBody.make(text: text, imageHashes: try images.map { try files.store($0) })
        let card = try await workspace.createCard(body: body, in: project)
        let destination = if let id = card.projectID { try await store.project(id) } else { nil as Project? }
        workspace.say(Dotted(CaptureCopy.saved(to: CaptureCopy.destination(destination))), link: .place(card.projectID))
    }
}

extension Workspace {
    /// Pi 的一条回答存为灵感：进该会话所属项目，没有项目进未分类；提示落点，点它过去。
    func saveReply(_ text: String, of session: PiSessionState) async throws {
        try await CaptureDraft(text: text, images: []).save(in: session.projectID, workspace: self)
    }
}
