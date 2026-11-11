#if DEBUG
import CueStore
import Foundation

/// 手机上要起飞、落地都在屏内时不配 `-CuePadBusyBoard`：第一张在待办那一行的头上，推进中卡少、新来的那张落在第一屏。
extension DebugScene {
    static func boardTourIfAsked(_ store: CueStore) async {
        guard args.driveOpts.boardTour else { return }
        await running("看板导览") { try await boardTour(store) }
    }

    private static func boardTour(_ store: CueStore) async throws {
        guard let task = try await TaskBoard.read(from: store).todo.first?.task else { return }
        // 每一步停留的时长是演示节奏，不是在等别的事
        let recorder = demoRecorder(store)
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
        // 在等你、不带 CuePad 答得了的问题：Cue 值班时也不归它答，算拍板（`SessionState.asksYou`）
        func session(_ state: WorkState) async throws {
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
