import CueStore
import Observation

/// 刚发给会话、页面还没读到的话：库里那条请求要下一次读库才进"在路上"，这一小段回复框的钮先当帧换成发送中，不先缩没再长出来。
/// 页面读到了（在路上，或 Agent 已接过去）就 `settle`，页面不在了也 `settle`；这句没写进库（`Workspace.speak` 放回了草稿）时 Workspace 立刻撤掉。
/// 对 Cue 说的这一份在 `CueWatch.launching`。
@Observable
final class Launching {
    private var keys: Set<String> = []

    func contains(_ session: PiSessionState) -> Bool { keys.contains(Self.key(session.hostID, session.target)) }
    func begin(_ session: PiSessionState) { keys.insert(Self.key(session.hostID, session.target)) }
    func settle(_ session: PiSessionState) { keys.remove(Self.key(session.hostID, session.target)) }
    func settle(host: String, target: SendTarget) { keys.remove(Self.key(host, target)) }

    private static func key(_ host: String, _ target: SendTarget) -> String { "\(host)\n\(target.name)" }
}
