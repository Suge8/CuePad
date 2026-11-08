import CueStore
import SwiftUI

/// 一个会话的菜单项（长按 / Mac 右键，或会话页的"⋯"）：会话出现的每一处共用这一份，有哪几项、什么顺序只在这里——
/// 标为未读、去它在等的那一处（`HandoffButton`）、置顶（绑着任务时：会话自己没有置顶，置的是那件任务，`SessionTask`）、重命名、
/// 跳到所在终端（Mac 本机桥上开在终端里的）、结束会话，手机与 iPad 上再隔一段是在它那台 Mac 上操作（`RemoteMacActions`）。看板上不归没做完的事的会话卡（`board`）与任务同一组操作：多一项完成（在做或在等你时先问，
/// `Workspace.finish`），置顶与重命名都落在当场给它建的那件任务上（`Workspace+Adopt`）。挂在会话列表的行（"更早"、搜索）、看板推进中与等你的会话卡、两端会话页的"⋯"上；
/// 手机会话行的左滑露出结束与重命名（`swipes`）。重命名与结束要再确认，交给窗口上那一格（`Workspace.sessionAsk`）。
struct SessionActions: View {
    let session: PiSessionState
    var task: SessionTask?
    /// 看板推进中、等你里没归没做完的事的会话卡（`BoardSessionCard`、`BoardWaitCard`）上的：那张卡的会话，完成、置顶、改名当场给它建任务。
    var board: PiSessionListItem?
    /// 结束请求在路上（`DeliveryRequest.shownEnd`）：结束会话置灰。
    var ending = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        MarkUnreadButton(session: session)
        HandoffButton(session: session)
        if let board {
            let session = session
            Button(CardMenu.Item.complete.title, icon: CardMenu.Item.complete.icon) { workspace.attempt { try await workspace.finish(board) } }
            Button(CardMenu.Item.pin.title, icon: CardMenu.Item.pin.icon) { workspace.attempt { try await workspace.pin(session) } }
        } else if let task {
            let item: CardMenu.Item = task.isPinned ? .unpin : .pin
            Button(item.title, icon: item.icon) { workspace.setPinned(task.id, !task.isPinned) }
        }
        if let rename = Self.rename(session, task: task, adopts: board != nil, in: workspace) { RowActionButtons(actions: [rename]) }
        #if os(macOS)
        if let bridge = workspace.services.pi.session(sessionID: session.sessionID), bridge.canJump {
            Button("跳到所在终端", icon: .terminal) { workspace.jumpToTerminal(bridge.id) }
        }
        #endif
        if let end = Self.end(session, ending: ending, in: workspace) { RowActionButtons(actions: [end]) }
        #if os(iOS)
        Section { RemoteMacActions(host: session.hostID) }
        #endif
    }

    /// 重命名：做得到的（`MacDelivery.canRename`，已结束的也能改；只读跟读的终端会话没有）；手机上够不着 Mac 时置灰。
    /// 预填此刻写的名字：绑着任务的是那个叶子的标题（`SessionTask.title`）。
    static func rename(_ session: PiSessionState, task: SessionTask? = nil, adopts: Bool = false, in workspace: Workspace) -> RowAction? {
        guard MacDelivery.canRename(session) else { return nil }
        let ask = SessionAsk.rename(session, shown: task?.title.nonEmpty ?? session.title, adopts: adopts)
        #if os(macOS)
        return RowAction("重命名…", icon: .rename) { workspace.sessionAsk = ask }
        #else
        return RowAction("重命名", icon: .rename, tone: .quiet, enabled: workspace.services.reachesPiHost) { workspace.sessionAsk = ask }
        #endif
    }

    /// 结束会话：还在线、做得到的（`PiSessionState.canEnd`），或从未解决的结束提示明确恢复。结束不是删除（对话留着，再说话就恢复），用墨色，确认框里再说清后果。
    static func end(_ session: PiSessionState, ending: Bool, recovering: Bool = false, in workspace: Workspace) -> RowAction? {
        guard session.canEnd || recovering else { return nil }
        return RowAction("结束会话", icon: .endSession, enabled: !ending) { workspace.sessionAsk = .end(session) }
    }

    /// 手机会话行慢慢左滑露出的：结束在最外侧，其次重命名。
    static func swipes(_ session: PiSessionState, task: SessionTask?, ending: Bool, in workspace: Workspace) -> RowSwipes {
        RowSwipes(trailing: [end(session, ending: ending, in: workspace), rename(session, task: task, in: workspace)].compactMap { $0 })
    }
}

/// 会话菜单里的"标为未读"：做完一轮停着、你看过了的会话才有（`PiUnread.canMarkUnread`）；
/// 标了之后它回到"有新回复"（石绿铃铛），直到你再打开它。
struct MarkUnreadButton: View {
    let session: PiSessionState
    @Environment(AppServices.self) private var services

    var body: some View {
        if services.settings.canMarkUnread(session) {
            Button("标为未读", icon: .markUnread) { services.settings.markUnread(session) }
        }
    }
}

/// 要你再确认一下的会话操作（`SessionActions` 置起）：改名的表单、结束的确认。窗口上只有一格弹它（`sessionAsks`）。
enum SessionAsk: Identifiable, Equatable {
    /// `shown` 是预填的名字（此刻写的那个）；`adopts`：看板上的会话卡发起的，没绑任务时先给它建任务（`Workspace.rename`）。
    case rename(PiSessionState, shown: String, adopts: Bool)
    case end(PiSessionState)
    /// 看板上在做或在等你的会话卡点了完成（`Workspace.finish`）：先问一句再建任务、完成。
    case complete(PiSessionState)

    var id: String {
        switch self {
        case .rename(let session, _, _): "rename/\(session.id)"
        case .end(let session): "end/\(session.id)"
        case .complete(let session): "complete/\(session.id)"
        }
    }
}
