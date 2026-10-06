import CueStore
import CueText
import Foundation

/// 随手记记成什么：想法存为卡片（可带图），任务存为一条任务（只有文字）。
nonisolated enum CaptureKind: String, CaseIterable, Sendable {
    case idea, task

    var label: String {
        switch self {
        case .idea: "想法"
        case .task: "任务"
        }
    }
}

/// 随手记的文案与存法（iOS 底部输入框、Mac 菜单栏面板共用）：输入框占位写明记成什么、落到哪；
/// 记下后的提示写明落点，点它去那里。
nonisolated enum CaptureCopy {
    static let inbox = "未归档"
    static let taskInbox = "任务"

    /// 落点的名字：想法没有项目时进未归档，任务没有项目时进任务页（不归任何项目）。
    static func destination(_ project: Project?, kind: CaptureKind) -> String {
        project?.name ?? (kind == .idea ? inbox : taskInbox)
    }

    static func placeholder(_ kind: CaptureKind, to destination: String) -> String {
        "\(kind == .idea ? "记下想法" : "记一条任务") → \(destination)"
    }

    static func saved(to destination: String) -> String { "已记到 \(destination)" }
}

/// 随手记的草稿：一段文字加若干图片。想法存成一张卡（文字在前，图片按顺序各占一行）；任务只存文字。
struct CaptureDraft {
    var text: String
    var images: [Data]
    var kind: CaptureKind

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isEmpty: Bool { kind == .task ? trimmed.isEmpty : trimmed.isEmpty && images.isEmpty }

    /// 存下并提示实际的落点（点提示去那里）；项目已失效时 `Workspace` 回落到未归档，提示照实写。
    func save(in project: UUID?, workspace: Workspace) async throws {
        let store = workspace.services.store
        func destination(_ id: UUID?) async throws -> String {
            let project = if let id { try await store.project(id) } else { Project?.none }
            return CaptureCopy.destination(project, kind: kind)
        }
        switch kind {
        case .idea:
            let files = store.files
            let body = StoredBody.make(text: text, imageHashes: try images.map { try files.store($0) })
            let card = try await workspace.createCard(body: body, in: project)
            workspace.say(CaptureCopy.saved(to: try await destination(card.projectID)), link: .project(card.projectID))
        case .task:
            let task = try await workspace.createTask(trimmed, in: project)
            workspace.say(CaptureCopy.saved(to: try await destination(task.projectID)), link: .tasks(task.projectID))
        }
    }
}

extension Workspace {
    /// Pi 的一条回答存为卡片：进该会话所属项目，没有项目进未归档；提示落点，点它过去。
    func saveReply(_ text: String, of session: PiSessionState) async throws {
        try await CaptureDraft(text: text, images: [], kind: .idea).save(in: session.projectID, workspace: self)
    }
}
