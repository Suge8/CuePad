import CueStore
import Foundation
import Observation
import SwiftUI

extension Workspace {
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

    func complete(_ id: UUID) async throws {
        let store = services.store
        let (status, undo, unreached) = try await store.completing(id, at: services.speech)
        guard status == .done else { return }
        if let undo { undoable("完成", undo) }
        let archiving = NoticeAction(title: String(localized: "归档")) { try await $0.archive(id) }
        let away = Set(unreached.map(\.sessionID))
        let stays = try await store.sessionsKept(afterCompleting: id).contains { !away.contains($0.sessionID) }
        say(stays ? "已完成，会话还在用，没有休眠" : "已完成", action: archiving, sound: .check)
        var failure: (any Error)?
        for session in unreached {
            do { _ = try await services.end(session) } catch { failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    func confirmComplete(
        _ task: UUID?, subtasks: TaskProgress?, busy: SessionState?, anchored: Bool = true,
        then proceed: @escaping @MainActor (Workspace) async throws -> Void
    ) async throws {
        var sleeps = true
        if let task, let busy { sleeps = try await services.store.sessionsEnding(byCompleting: task, at: services.speech).contains(busy.sessionID) }
        if let ask = CompletionAsk(subtasks: subtasks, busy: busy, sleeps: sleeps) {
            let claimer = anchored ? task.flatMap { completionClaims[$0]?.last } : nil
            return sessionAsk = .complete(ask, claimer: claimer, then: proceed)
        }
        try await proceed(self)
    }

    func confirmComplete(_ task: Card) async throws {
        let id = task.id
        let subtasks = try await services.store.subtaskProgress(of: [id])[id]
        try await confirmComplete(id, subtasks: subtasks, busy: next(for: task, in: agentLinks, steps: subtasks)?.busySession) { try await $0.complete(id) }
    }

    func reopen(_ id: UUID) async throws {
        try await services.store.reopenTask(id)
    }

    func mergeIdea(_ idea: UUID, into task: UUID) async throws {
        let store = services.store
        let undo = try await store.merging(idea, into: task)
        leave(.card(idea))
        let title = try await store.card(task)?.title ?? ""
        say("已接到「\(title.textGlyphs)」的正文后面", action: .undo("合并", undo))
    }

    func newTask(fromIdea idea: UUID) async throws {
        let (task, undo) = try await services.store.spawning(idea)
        leave(.card(idea))
        say("已新建任务「\(task.title.textGlyphs)」", action: .undo("新建任务", undo))
    }

    func leaveEditing(_ id: UUID, flush: Autosave?, heading: String) {
        let store = services.store
        attempt {
            do {
                try await flush?.flush()
            } catch {
                if let text = flush?.unsaved {
                    self.unsavedBodies[id] = UnsavedBody(text: text, base: try? await store.card(id)?.body)
                }
                throw error
            }
            try await store.dropIfBlank(id)
            if let card = try await store.card(id), card.isTask, card.heading != heading { try await self.pushName(of: id) }
        }
    }

    func openTask(id: UUID) {
        let store = services.store
        attempt {
            guard let card = try await store.card(id), card.deletedAt == nil else { return self.say("这件任务已删除", tone: .gone) }
            guard card.archivedAt == nil else { return self.say("这件任务已归档", tone: .gone) }
            self.openTask(card)
        }
    }

    func pressed(at point: CGPoint) { press.record(point) }

    func enter(_ task: Card, session: SessionState?, in column: Column = .main) {
        guard let session else { return openTask(task) }
        openTask = nil
        openSession(session.id, sessionID: session.sessionID, in: column)
    }

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

    func move(_ id: UUID, to slot: CardSlot, after previous: UUID?) {
        let store = services.store
        attempt { self.undoable("移动", try await store.moving(id, to: slot, after: previous)) }
    }

    func archive(_ id: UUID) async throws {
        let store = services.store
        let change = try await store.archive(id)
        leave(.card(id))
        say("已归档", action: .undo("归档") { try await store.undo(change) })
    }

    func trash(_ id: UUID) async throws { try await trash([id]) }

    func trash(_ ids: [UUID]) async throws {
        let undo = try await services.store.trashing(ids)
        for id in ids { leave(.card(id)) }
        #if os(macOS)
        // 卡从墙上拿走时收不到鼠标移出：不再算停在它上面（⌘⌫ 删的是鼠标停着的那张）
        ids.forEach { presses.hover($0, inside: false) }
        #endif
        say(ids.count > 1 ? "已删除 \(ids.count) 条" : "已删除", action: .undo("删除", undo))
    }

    func archiveCompletedTasks() async throws {
        let count = try await services.store.archiveCompletedTasks(in: scopedProject)
        if count > 0 { say("已归档 \(count) 项任务") }
    }

    func copy(_ stored: String) {
        do {
            try services.copy(stored)
            say("已复制")
        } catch {
            fail(error)
        }
    }
}

enum CompletionAsk: Equatable {
    case steps(TaskProgress)
    case agent(SessionState, sleeps: Bool)

    init?(subtasks: TaskProgress?, busy: SessionState?, sleeps: Bool) {
        if let subtasks, TaskCopy.hasOpen(subtasks) {
            self = .steps(subtasks)
        } else if let busy {
            self = .agent(busy, sleeps: sleeps)
        } else {
            return nil
        }
    }
}
