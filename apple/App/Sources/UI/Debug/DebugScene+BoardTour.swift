#if DEBUG
import CueStore
import Foundation

/// `-CuePadBoardTour YES`（配 progress 画面与 `-CuePadDemo YES`，就绪后一直循环）：待办里"续费域名"依次走过看板各列，录卡的进出、换列与列内换位（`xc.sh rec`）——
/// 交给 Agent（到推进中）→ 要你确认（到等你）→ 做完（到已完成）→ 归档（离开看板）→ 重新打开（取回归档，出现在待办）→ 排到待办最前，再从交给 Agent 开始。
extension DebugScene {
    static func boardTourIfAsked(_ store: CueStore) async {
        guard defaults.bool(forKey: "CuePadBoardTour") else { return }
        let title = String(localized: "续费域名", table: "Demo")
        guard let task = try? await store.tasks(.todo).flatMap(\.tasks).first(where: { $0.parentID == nil && $0.body.hasPrefix(title) }) else { return }
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
