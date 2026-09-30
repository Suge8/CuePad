#if os(iOS)
import CueStore
import Foundation

/// "发到 Mac"的界面规则：会话此刻可用哪些发送方式。请求本身经 `AppServices.requestMacDelivery` 写出。
nonisolated enum MacDelivery {
    /// 会话此刻可用的方式：忙（干活或等你确认）时直接发送会被 Pi 拒绝，只能插话或排队；含图片时不能放进输入框。
    static func modes(for state: Open<PiWorkState>, hasImages: Bool) -> [DeliveryMode] {
        let busy = state.isWorking || state == .known(.waitingForUser)
        let sending: [DeliveryMode] = busy ? [.steer, .followUp] : [.send]
        return hasImages ? sending : sending + [.paste]
    }
}

nonisolated extension DeliveryMode {
    var label: String {
        switch self {
        case .send: "直接发送"
        case .steer: "插话"
        case .followUp: "排队"
        case .paste: "放进输入框"
        }
    }

    /// 不直观的方式才需要一句说明。
    var explanation: String? {
        switch self {
        case .steer: "打断 Pi 正在进行的这一轮"
        case .followUp: "等 Pi 这一轮结束后再发"
        case .paste: "只放进输入框，由你在 Mac 上确认发送"
        case .send: nil
        }
    }
}

nonisolated extension Open<DeliveryMode> {
    var label: String { known?.label ?? rawValue }
}
#endif
