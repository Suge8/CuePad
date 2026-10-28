import CueStore
import Foundation
import Observation
import SwiftUI

extension Workspace {
    /// 新建卡片。项目是否有效由 Store 在写事务里判定：项目已不存在或在回收站（`invalidProject`）时，
    /// 重新核对当前项目，卡片落到默认项目并提示，不会写进看不见的地方。
    func createCard(body: String = "", in project: UUID) async throws -> Card {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createCard(in: $0, body: body) }
    }

    /// 新建任务；项目失效时同样回落，任务进默认项目并提示。
    func createTask(_ body: String, in project: UUID) async throws -> Card {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createTask(body, in: $0) }
    }

    private func fallingBack<T>(from project: UUID, _ write: (UUID) async throws -> T) async throws -> T {
        do {
            return try await write(project)
        } catch CueStoreError.invalidProject where project != Project.defaultID {
            #if os(macOS)
            await reconcileCurrentProject()
            #endif
            let result = try await write(Project.defaultID)
            say("原项目已不存在或在回收站，已放到默认项目", tone: .failure)
            return result
        }
    }

    /// 点任务的圆圈：待办与进行中都变完成，完成的不再算做完（开始过的回到进行中）。下一个状态由 Store 在一个事务里按当前值定（`toggleDone`）：
    /// 界面手里的副本可能已过时（列表还没刷新就又点了一次）。
    /// 完成就是做完了：它（和它的子任务）绑着的会话里，绑着的事都做完了的一起结束——结束哪些只由 Store 定（`CueStore.toggleDone`，
    /// 与 Cue 的 done 同一条规则），结束请求写下就上传。
    func toggle(_ id: UUID) async throws {
        let (status, ended) = try await services.store.toggleDone(id)
        for request in ended { _ = services.uploaded(request) }
        // 做完了就给一个归档（不自动归档）
        guard status == .done else { return }
        say("已完成", action: NoticeAction(title: String(localized: "归档")) { try await self.archive(id) })
    }

    /// 灵感拖到一条任务上：接到它的正文后面，灵感进回收站（一次写入）；提示里带"撤销"。灵感变成要做的事只有这一步与 `newTask(fromIdea:)`。
    func mergeIdea(_ idea: UUID, into task: UUID) async throws {
        let store = services.store
        let undo = try await store.merging(idea, into: task)
        closeIfOpen(idea)
        let title = try await store.card(task)?.title ?? ""
        say("已接到「\(title.textGlyphs)」的正文后面", action: .undo(undo))
    }

    /// 灵感拖到"添加任务"上：照它新建一条任务（在它的项目里排最前），灵感进回收站（一次写入）；提示里带"撤销"。
    func newTask(fromIdea idea: UUID) async throws {
        let (task, undo) = try await services.store.spawning(idea)
        closeIfOpen(idea)
        say("已新建任务「\(task.title.textGlyphs)」", action: .undo(undo))
    }

    /// 离开一条灵感或任务正文的编辑：先写下没保存的字，还是空白（`Card.isBlank`）的灵感就不留下——记一条是先建一条空的再编辑。
    func leaveEditing(_ id: UUID, flush: Autosave?) {
        let store = services.store
        attempt {
            await flush?.flush()
            try await store.dropIfBlank(id)
        }
    }

    /// 这一条归档或删掉了：开着它的编辑页或任务气泡收起。
    private func closeIfOpen(_ id: UUID) {
        #if os(macOS)
        close(.card(id))
        #endif
        if openTask?.task == id { openTask = nil }
    }

    /// 按 id 打开任务的气泡（Cue 页里提到的任务）：先从库里读到它，再同 `openTask(_:)`。删掉、归档了的气泡开了也立刻收起（`TaskBubble` 的 `gone`），
    /// 不开，说一句它去哪了。
    func openTask(id: UUID) {
        let store = services.store
        attempt {
            guard let card = try await store.card(id), card.deletedAt == nil else { return self.say("这件任务已删除", tone: .gone) }
            guard card.archivedAt == nil else { return self.say("这件任务已归档", tone: .gone) }
            self.openTask(card)
        }
    }

    func pressed(at point: CGPoint) { press.record(point) }

    /// 点一条任务（项目页的任务行、看板的卡同一条规则）：它写着哪个会话的状态就进那个会话——看板的卡是此刻干活那一步的
    /// （`TaskBoard.Item.agent`，有子任务的也是），任务行是这条自己交给的（做完了也算）；没有会话的打开任务气泡（改标题与正文，子任务在气泡里）。
    /// 进会话的那一下，任务气泡从长按菜单的"打开任务"进（`CardActions` 的 `opens`）。
    func enter(_ task: Card, session: PiSessionState?) {
        guard let session else { return openTask(task) }
        openTask = nil
        openSession(session.id, sessionID: session.sessionID)
    }

    /// 打开一条任务的气泡（没开工的任务行、Cue 对话里的任务、⌘K、归档、小组件链接都经这里）：从刚按下的那一下长出来；
    /// 不是刚点的（键盘、⌘K 里按 ↩、链接）就没有落点，气泡在窗口上方居中。子任务是它上级的气泡、翻到这一项；
    /// 这件事的气泡已经开着时（气泡里点子任务、返回）原地翻页，不重新长一次。
    func openTask(_ card: Card) {
        let task = card.parentID ?? card.id, step = card.parentID == nil ? nil : card.id
        if openTask?.task == task {
            openTask?.step = step
            return
        }
        if let closed = closedTask, closed.task == task, PressPoint.reopens(closedAt: closed.at) { return closedTask = nil }
        openTask = TaskBubble.Request(task: task, step: step, source: press.source)
    }

    /// 置顶、取消置顶一条卡（灵感与顶层任务；会话菜单里的置顶也落在它绑着的任务上）。
    func setPinned(_ card: UUID, _ pinned: Bool) {
        perform { try await $0.updateCard(card) { $0.isPinned = pinned } }
    }

    /// 归档（连同下级）：不占列表、仍可搜；提示里可撤销。
    func archive(_ id: UUID) async throws {
        let store = services.store
        try await store.archive(id)
        closeIfOpen(id)
        say("已归档", action: .undo { try await store.unarchive(id) })
    }

    /// 删除灵感或任务（一条，或 Mac 上批量选中的几条，一次写入）：提示里可撤销，撤销把这一批一起拨回。
    func trash(_ id: UUID) async throws { try await trash([id]) }

    func trash(_ ids: [UUID]) async throws {
        let undo = try await services.store.trashing(ids)
        ids.forEach(closeIfOpen)
        #if os(macOS)
        // 卡从墙上拿走时收不到鼠标移出：不再算停在它上面（⌘⌫ 删的是鼠标停着的那张）
        ids.forEach { presses.hover($0, inside: false) }
        #endif
        say(ids.count > 1 ? "已删除 \(ids.count) 条" : "已删除", action: .undo(undo))
    }

    func archiveCompletedTasks() async throws {
        let count = try await services.store.archiveCompletedTasks()
        if count > 0 { say("已归档 \(count) 项任务") }
    }

    /// 复制正文（存储格式，变量已填）到剪贴板：普通的复制，不是发送，不记发送记录。
    func copy(_ stored: String) {
        do {
            try services.copy(stored)
            say("已复制")
        } catch {
            fail(error)
        }
    }

    func run(_ action: NoticeAction) {
        notice = nil
        attempt { try await action.run() }
    }
}
