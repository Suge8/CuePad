import CueStore
import Foundation

/// "发到 Mac"的界面规则：会话此刻可用哪些发送方式。请求本身经 `AppServices.requestMacDelivery` 写出。
nonisolated enum MacDelivery {
    /// 会话此刻可用的方式，第一个是默认：Pi 正在跑一轮时直接发送会被拒绝，只能插话或排队。
    /// Mac 上人就在 Pi 旁边：默认插话，也可以只放进输入框再自己按发送（含图片时不能）。
    /// 手机上人不在 Mac 前：默认等它做完再说，另有马上说；不给放进输入框（没人去按那一下发送）。
    static func modes(for state: Open<PiWorkState>, hasImages: Bool) -> [DeliveryMode] {
        let busy = state.known?.isTurnRunning == true
        #if os(macOS)
        let sending: [DeliveryMode] = busy ? [.steer, .followUp] : [.send]
        return hasImages ? sending : sending + [.paste]
        #else
        return busy ? [.followUp, .steer] : [.send]
        #endif
    }
}

nonisolated extension DeliveryMode {
    var label: String {
        switch self {
        case .send: "直接发送"
        case .steer: "插话"
        case .followUp: "排队"
        case .paste: "放进输入框"
        case .answer: "作答"
        case .ping: "连接测试"
        case .resume: "继续会话"
        case .start: "新会话"
        }
    }

    /// 方式是什么意思，用直白的话（按钮上只写短名）。
    var explanation: String? {
        switch self {
        case .steer: "马上说（打断它正在做的）"
        case .followUp: "等它做完再说"
        case .paste: "只放进输入框，不发送"
        case .send, .answer, .ping, .resume, .start: nil
        }
    }
}

nonisolated extension Open<DeliveryMode> {
    var label: String { known?.label ?? rawValue }
}
