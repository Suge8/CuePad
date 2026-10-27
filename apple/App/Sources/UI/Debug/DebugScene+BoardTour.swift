#if DEBUG
import CueStore
import Foundation

/// `-CuePadBoardTour YES`（配 progress 画面与 `-CuePadDemo YES`，就绪后一直循环）：看板待办的第一张依次走过看板各列，录卡的进出、换列与列内换位（`xc.sh rec`）——
/// 起头一次：排在最后的项目里一个会话开了一轮、再一个排在最后、有待办的项目开始一件（项目各自排到前面，侧栏与待办按项目的分组同步）；之后循环：交给 Agent（开始，它的项目排回前面）（到推进中）→ 要你确认（到等你）→ 做完（到已完成）→ 待办的第二张归档再取回（从一列中间离开、回来：归档、取回不算项目的进展，
/// 整列不重排，`CueStore.projectOrder`）
/// → 归档（离开看板）→ 重新打开（取回归档，出现在待办）→ 排到它项目的最前，再从交给 Agent 开始。
/// 手机上要起飞、落地都在屏内时不配 `-CuePadBusyBoard`：第一张在待办那一行的头上，推进中卡少、新来的那张落在第一屏。
extension DebugScene {
    static func boardTourIfAsked(_ store: CueStore) async {
        guard defaults.bool(forKey: "CuePadBoardTour") else { return }
        await running("看板导览") { try await boardTour(store) }
    }

    private static func boardTour(_ store: CueStore) async throws {
        guard let task = try await TaskBoard.read(from: store).todo.first?.task else { return }
        // 每一步停留的时长是演示节奏，不是在等别的事
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        func pause() async { await Task.wait(for: .seconds(2.5)) }
        if let last = try await store.projects().last(where: { !$0.isPinned && !$0.isDefault }) {
            await pause()
            _ = try await recorder.update(sessionID: "tour-talk", state: .thinking, title: "talk", projectID: last.id, turnStartedAt: .now)
        }
        for project in try await store.projects().reversed().filter({ !$0.isPinned }) {
            guard let started = try await store.tasks(in: project.id, .todo).first(where: { $0.parentID == nil && $0.id != task.id }) else { continue }
            await pause()
            try await store.setStatus(started.id, .inProgress)
            break
        }
        // 在等你、不带 CuePad 答得了的问题：Cue 值班时也不归它答，算拍板（`PiSessionState.asksYou`）
        func session(_ state: PiWorkState) async throws {
            _ = try await recorder.update(sessionID: "renew", state: state, title: "renew", directory: "renew")
        }
        while !Task.isCancelled {
            await pause()
            try await session(.thinking)
            try await store.linkCard(task.id, toSession: "renew")
            await pause()
            try await session(.waitingForUser)
            await pause()
            try await store.setStatus(task.id, .done)
            try await session(.ended)
            if let middle = try await TaskBoard.read(from: store).todo.dropFirst().first?.task {
                await pause()
                try await store.archive(middle.id)
                await pause()
                try await store.unarchive(middle.id)
            }
            await pause()
            try await store.archive(task.id)
            await pause()
            try await store.setStatus(task.id, .todo)
            await pause()
            _ = try await store.moveCard(task.id, to: .top(project: task.projectID), after: nil)
        }
    }
}
#endif
