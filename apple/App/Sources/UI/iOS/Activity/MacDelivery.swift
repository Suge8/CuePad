#if os(iOS)
import CueStore
import Foundation

/// "发到 Mac"：手机写一条投送请求，经 iCloud 交给运行该 Pi 会话的那台 Mac 执行；
/// Mac 执行后写回结果，并在它那边记发送记录（同步回来）。
nonisolated enum MacDelivery {
    /// 发送方式。原始值是与 Mac 执行器约定的 `DeliveryRequest.mode`。
    enum Mode: String, CaseIterable, Hashable, Sendable {
        /// 直接发送（会话空闲时）。
        case send
        /// 插话：打断正在进行的这一轮。
        case steer
        /// 排队：这一轮结束后再发。
        case followUp
        /// 只放进 Pi 的输入框，不发送；只有文字。
        case paste

        var label: String {
            switch self {
            case .send: "直接发送"
            case .steer: "插话"
            case .followUp: "排队"
            case .paste: "放进输入框"
            }
        }

        var explanation: String {
            switch self {
            case .send: "Pi 立即开始处理"
            case .steer: "打断 Pi 正在进行的这一轮"
            case .followUp: "等 Pi 这一轮结束后再发"
            case .paste: "只放进输入框，由你在 Mac 上确认发送"
            }
        }
    }

    /// 会话此刻可用的方式：忙（干活或等你确认）时直接发送会被 Pi 拒绝，只能插话或排队；含图片时不能放进输入框。
    static func modes(for state: PiWorkState, hasImages: Bool) -> [Mode] {
        let busy = state.isWorking || state == .waitingForUser
        let sending: [Mode] = busy ? [.steer, .followUp] : [.send]
        return hasImages ? sending : sending + [.paste]
    }

    @discardableResult
    static func request(
        _ stored: String, to session: PiSessionState, mode: Mode, card: UUID?, task: UUID?, in store: CueStore
    ) async throws -> DeliveryRequest {
        try await store.requestDelivery(
            stored, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID,
            mode: mode.rawValue, card: card, task: task)
    }
}
#endif
