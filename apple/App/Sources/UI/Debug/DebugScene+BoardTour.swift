#if DEBUG
import CueStore
import Foundation

/// `-CuePadBoardTour YES`（配 progress 画面与 `-CuePadDemo YES`，就绪后一直循环）：看板待办的第一张依次走过看板各列，录卡的进出、换列与列内换位（`xc.sh rec`）——
/// 交给 Agent（到推进中）→ 要你确认（到等你）→ 做完（到已完成）→ 已完成的第二张归档再取回（从一列中间离开、回来；已完成按做完的时刻排，
/// 取回落回原处。不取待办里的：待办按项目最近的活动排，归档一张会把它的项目整组顶到列顶，录到的是换序）
/// → 归档（离开看板）→ 重新打开（取回归档，出现在待办）→ 排到它项目的最前，再从交给 Agent 开始。
/// 手机上要起飞、落地都在屏内时不配 `-CuePadBusyBoard`：第一张在待办那一行的头上，推进中卡少、新来的那张落在第一屏。
extension DebugScene {
    static func boardTourIfAsked(_ store: CueStore) async {
        guard defaults.bool(forKey: "CuePadBoardTour") else { return }
        guard let task = try? await TaskBoard.read(from: store).todo.first?.task else { return }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        // 在等你、不带 CuePad 答得了的问题：Cue 值班时也不归它答，算拍板（`PiSessionState.asksYou`）
        func session(_ state: PiWorkState) async {
            _ = try? await recorder.update(sessionID: "renew", state: state, title: "renew", directory: "renew")
        }
        // 每一步停留的时长是演示节奏，不是在等别的事
        func pause() async { try? await Task.sleep(for: .seconds(2.5)) }
        while !Task.isCancelled {
            await pause()
            await session(.thinking)
            try? await store.linkCard(task.id, toSession: "renew")
            await pause()
            await session(.waitingForUser)
            await pause()
            try? await store.setStatus(task.id, .done)
            await session(.ended)
            if let board = try? await TaskBoard.read(from: store), let middle = (board.done + board.earlier).dropFirst().first?.task {
                await pause()
                try? await store.archive(middle.id)
                await pause()
                try? await store.unarchive(middle.id)
            }
            await pause()
            try? await store.archive(task.id)
            await pause()
            try? await store.setStatus(task.id, .todo)
            await pause()
            _ = try? await store.moveCard(task.id, to: .top(project: task.projectID), after: nil)
        }
    }
}
#endif
