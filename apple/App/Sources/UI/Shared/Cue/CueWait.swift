import CueStore
import Foundation

/// Cue 页拍板卡上的一件（`CueStore.cueWaiting`）：Cue 的提问，或会话在问你的；落在任务上的带那件顶层任务。
/// 写什么在 `WaitParts`（问句）与 `CueWaitEyebrow`（眉题），露哪件记在 `Workspace.cueAsking`。
nonisolated struct CueWait: Identifiable, Sendable, Equatable {
    var wait: CueTally.Wait
    var task: Card?
    var id: String { wait.id }

    /// Cue 的提问；会话在问的是 nil。
    var message: CueMessage? {
        if case .message(let message, _) = wait { message } else { nil }
    }

    /// 这件事叫什么（眉题）：落在的任务名，没绑任务的会话名；不落在任务上的 Cue 提问没有这件事，为 nil。
    var title: String? {
        if let task { return task.title }
        if case .session(let session, _) = wait { return session.title }
        return nil
    }

    /// 等了多久从哪算：Cue 提问的时刻，会话进入等你的时刻。
    var since: Date {
        switch wait {
        case .message(let message, _): message.createdAt
        case .session(let session, _): session.stateSince
        }
    }

    /// 归哪个项目（眉题上写的是它）：落在的任务的项目，没落在任务上的会话看它的归处（`TaskBoard.home`），
    /// Cue 的一般提问是它问时的范围（`CueMessage.asked`），没给范围的不属于哪个项目。
    var project: UUID? {
        if let task { return task.projectID }
        switch wait {
        case .session(let session, _): return TaskBoard.home(session)
        case .message(let message, _): return message.asked?.project
        }
    }

    /// 最早的在前（等得最久的先答）。
    static func read(_ waiting: [CueTally.Wait], from store: isolated CueStore) throws -> [CueWait] {
        try waiting.map { wait in CueWait(wait: wait, task: try wait.task.flatMap { try store.card($0) }) }
            .enumerated().sorted { ($0.element.since, $0.offset) < ($1.element.since, $1.offset) }.map(\.element)
    }
}
