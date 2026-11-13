import CueStore
import Foundation
import Observation
import SwiftUI

extension Workspace {
    /// 项目失效时由写事务选择默认项目；界面按实际落点纠正导航并提示。
    func createCard(body: String = "", in project: UUID) async throws -> Card {
        let card = try await services.store.createCard(in: project, body: body, ifProjectMissing: .useDefault)
        return await created(card, requested: project)
    }

    func createTask(_ body: String, in project: UUID) async throws -> Card {
        let card = try await services.store.createTask(body, in: project, ifProjectMissing: .useDefault)
        return await created(card, requested: project)
    }

    private func created(_ card: Card, requested project: UUID) async -> Card {
        if card.projectID != project {
            await reconcileCurrentProject()
            say("原项目已不存在或在回收站，已放到默认项目", tone: .failure)
        }
        return card
    }

    /// 已经完成的不动：界面手里的副本可能已过时（别的设备刚做完），再来一次不能把它翻回去（`CueStore.completeTask`）。
    /// 绑着的会话里绑着的事都做完了的一起结束，结束哪些只由 Store 定（与 Cue 的 done 同一条规则）。
    func complete(_ id: UUID) async throws {
        let (status, ended, undo) = try await services.store.completing(id)
        for request in ended { _ = services.uploaded(request) }
        // 做完了就给一个归档（不自动归档）
        guard status == .done else { return }
        if let undo { undoable("完成", undo) }
        let archiving = NoticeAction(title: String(localized: "归档")) { try await $0.archive(id) }
        say("已完成", action: archiving, sound: .check)
    }

    func reopen(_ id: UUID) async throws {
        try await services.store.reopenTask(id)
    }

    /// 灵感变成要做的事只有这一步与 `newTask(fromIdea:)`。
    func mergeIdea(_ idea: UUID, into task: UUID) async throws {
        let store = services.store
        let undo = try await store.merging(idea, into: task)
        leave(idea)
        let title = try await store.card(task)?.title ?? ""
        say("已接到「\(title.textGlyphs)」的正文后面", action: .undo("合并", undo))
    }

    func newTask(fromIdea idea: UUID) async throws {
        let (task, undo) = try await services.store.spawning(idea)
        leave(idea)
        say("已新建任务「\(task.title.textGlyphs)」", action: .undo("新建任务", undo))
    }

    /// 还是空白（`Card.isBlank`）的灵感就不留下：记一条是先建一条空的再编辑。
    func leaveEditing(_ id: UUID, flush: Autosave?, heading: String) {
        let store = services.store
        attempt {
            do {
                try await flush?.flush()
            } catch {
                // 页面已经走了，待写的字交给 Workspace 带着：再打开这条时接回来、再试着写
                if let text = flush?.unsaved {
                    self.unsavedBodies[id] = UnsavedBody(text: text, base: try? await store.card(id)?.body)
                }
                throw error
            }
            try await store.dropIfBlank(id)
            if let card = try await store.card(id), card.isTask, card.heading != heading { try await self.pushName(of: id) }
        }
    }

    private func leave(_ card: UUID) {
        leave(.card(card))
        if openTask?.task == card { openTask = nil }
    }

    /// 删掉、归档了的不开，说一句它去哪了。
    func openTask(id: UUID) {
        let store = services.store
        attempt {
            guard let card = try await store.card(id), card.deletedAt == nil else { return self.say("这件任务已删除", tone: .gone) }
            guard card.archivedAt == nil else { return self.say("这件任务已归档", tone: .gone) }
            self.openTask(card)
        }
    }

    func pressed(at point: CGPoint) { press.record(point) }

    /// 项目页的任务行、看板的卡同一条规则：看板的卡是此刻干活那一步的（`TaskBoard.Item.agent`，有子任务的也是），任务行是这条自己交给的（做完了也算）。
    func enter(_ task: Card, session: SessionState?, in column: Column = .main) {
        guard let session else { return openTask(task) }
        openTask = nil
        openSession(session.id, sessionID: session.sessionID, in: column)
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

    func setPinned(_ card: UUID, _ pinned: Bool) {
        let store = services.store
        attempt { self.undoable(pinned ? "置顶" : "取消置顶", try await store.pinning(card, pinned)) }
    }

    /// 排序、换项目、缩进、挂成子任务（`CueStore.moveCard`）。
    func move(_ id: UUID, to slot: CardSlot, after previous: UUID?) {
        let store = services.store
        attempt { self.undoable("移动", try await store.moving(id, to: slot, after: previous)) }
    }

    func archive(_ id: UUID) async throws {
        let store = services.store
        let time = try await store.archive(id)
        leave(id)
        say("已归档", action: .undo("归档") { try await store.unarchive(id, archivedAt: time) })
    }

    func trash(_ id: UUID) async throws { try await trash([id]) }

    func trash(_ ids: [UUID]) async throws {
        let undo = try await services.store.trashing(ids)
        ids.forEach(leave)
        #if os(macOS)
        // 卡从墙上拿走时收不到鼠标移出：不再算停在它上面（⌘⌫ 删的是鼠标停着的那张）
        ids.forEach { presses.hover($0, inside: false) }
        #endif
        say(ids.count > 1 ? "已删除 \(ids.count) 条" : "已删除", action: .undo("删除", undo))
    }

    /// 归档的就是看板上此刻看得到的那些已完成：选了项目范围只归档那个项目的。入口都在看板的已完成那一列，范围只在这里读。
    func archiveCompletedTasks() async throws {
        let count = try await services.store.archiveCompletedTasks(in: scopedProject)
        if count > 0 { say("已归档 \(count) 项任务") }
    }

    /// 普通的复制，不是发送，不记发送记录。
    func copy(_ stored: String) {
        do {
            try services.copy(stored)
            say("已复制")
        } catch {
            fail(error)
        }
    }
}
