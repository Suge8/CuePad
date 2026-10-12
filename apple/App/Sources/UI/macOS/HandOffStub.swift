#if os(macOS)
import CueStore
// 临时：合并 feat/mac-send-destination 后删除
extension Workspace {
    func handOff(_ prompt: Card) {
        guard let target = sendState.agentTarget(for: prompt.projectID) else { return open(prompt) }
        let text = Outgoing.text(of: prompt), id = prompt.id
        Task { await send(text, to: target, card: id) }
    }
}
#endif
