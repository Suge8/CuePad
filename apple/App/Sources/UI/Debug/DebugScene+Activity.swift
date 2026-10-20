#if os(iOS) && DEBUG
import CueStore
import Foundation
import UIKit

/// `-CuePadActivityDrain YES`（配 `-CuePadDemo YES`，iPhone）：验收实时活动跟着库走到结束。App 在前台按演示库开起实时活动（`CueLiveActivity`），
/// 之后每回到前台一次（点灵动岛回来）处理掉一件：先答等你（Cue 的提问走"允许一次"同一个回答方法 `AppServices.answerCueQuestion`；会话在问的由演示 Mac
/// 写成它接着在做），再把在管的逐件点完成（`Workspace.toggle`），直到在管与等你都没有。退到桌面就看得到灵动岛跟着变、最后消失。
/// 每一步写一行到隔离库目录的 activity-drain.log（时刻、做了什么、做完后的在管与等你），截图按它对时。
extension DebugScene {
    static func activityDrainIfAsked(_ workspace: Workspace) async {
        guard defaults.bool(forKey: "CuePadActivityDrain") else { return }
        let services = workspace.services, store = services.store
        let log = services.location.directory.appending(path: "activity-drain.log")
        try? Data().write(to: log)
        func note(_ line: String) async {
            let tally = (try? await store.cueTally()) ?? .empty
            let text = "\(Date.now.timeIntervalSince1970) \(line) 在管 \(tally.managing.count) 等你 \(tally.waiting.count)\n"
            if let handle = try? FileHandle(forWritingTo: log) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            }
        }
        await note("开始")
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
            guard let tally = try? await store.cueTally() else { return }
            if let wait = tally.waiting.first {
                switch wait {
                case .message(let message, _):
                    try? await services.answerCueQuestion(message.id, message.choices?.first ?? CueAsk.once)
                    await note("允许一次")
                case .session(let state, _):
                    try? await PiStateRecorder(store: store, hostID: state.hostID).update(sessionID: state.sessionID, state: .thinking)
                    await note("会话答完 \(state.title)")
                }
            } else if let task = tally.managing.first {
                try? await workspace.toggle(task.id)
                await note("做完 \(task.title)")
            } else {
                return await note("结束")
            }
        }
    }
}
#endif
