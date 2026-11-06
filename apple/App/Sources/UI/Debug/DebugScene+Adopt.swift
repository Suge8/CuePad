#if DEBUG
import CueStore
import Foundation

/// `-CuePadAdopt done:<会话名>,pin:<会话名>`（配 progress 画面与 `-CuePadDemo YES`）：摆画面时把看板推进中这几个不归没做完的事的会话当任务用——
/// done 同拖到已完成、pin 同菜单里的置顶（`Workspace+Adopt`），看当场建出来的任务卡（标题为空，写的是会话名）落在哪一列。
extension DebugScene {
    static func adoptIfAsked(_ workspace: Workspace) async throws {
        guard let asked = defaults.string(forKey: "CuePadAdopt") else { return }
        let loose = try await workspace.services.store.cueBoard().sessions
        for step in asked.split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let session = loose.first(where: { $0.title == parts[1] }) else { continue }
            switch parts[0] {
            case "done": try await workspace.complete(session)
            case "pin": try await workspace.pin(session)
            default: continue
            }
        }
    }
}
#endif
