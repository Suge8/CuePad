#if DEBUG
import CueStore
import Foundation

extension DebugScene {
    /// `-CuePadRelayKind mixed`：一次读取同时看到已结束与仍活跃的新会话；活跃格必须接力后露出，不能等已结束目标进入会话条。
    static func relayMixed(_ store: CueStore, on launcher: StateRecorder) async throws -> [DeliveryRequest] {
        let tokens = [UUID().uuidString, UUID().uuidString]
        for (index, state) in [WorkState.ended, .thinking].enumerated() {
            try await launcher.update(
                sessionID: "relay-\(index)", state: state, title: "relay-\(index)", directory: "demo",
                projectID: Project.defaultID, launchToken: tokens[index])
        }
        return try await relayRequests(store, tokens: tokens)
    }

    // 同一段 actor 隔离中写完两条请求，订阅者下一次读取必须同时看见两个认领结果。
    private static func relayRequests(_ store: isolated CueStore, tokens: [String]) throws -> [DeliveryRequest] {
        try tokens.enumerated().map { index, token in
            try store.requestLaunch(
                LaunchRequest(project: Project.defaultID, prompt: "relay-\(index)", token: token), title: "relay-\(index)", on: "demo-mac", cue: true)
        }
    }
}
#endif
