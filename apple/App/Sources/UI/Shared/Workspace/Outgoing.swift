import CueStore
import CueText
import Foundation
#if os(macOS)
import CueDispatch
import CuePi
#endif

/// 卡片发出去（发送、复制、分享）的正文：变量已填、编号已排。
nonisolated enum Outgoing {
    static func text(of card: Card) -> String {
        text(body: card.body, values: card.variableValues, numbering: card.numbering)
    }

    static func text(body: String, values: [String: String], numbering: Open<CueNumbering>) -> String {
        CueSegments.format(CueVariables.fill(body, values: values), numbering: numbering.known ?? .none)
    }
}

/// 错误的界面文案。
enum ErrorText {
    static func describe(_ error: any Error) -> String {
        switch error {
        case CueStoreError.invalidProject: "目标项目已不存在或在回收站"
        #if os(macOS)
        case DispatchError.accessibilityRequired: "需要在设置里授权辅助功能才能投送到其他应用"
        case DispatchError.noTarget: "没有可投送的目标应用"
        case DispatchError.targetUnavailable: "目标应用没有在运行"
        case DispatchError.clipboardWriteFailed: "写入剪贴板失败"
        case PiBridgeError.unknownSession: "这个 Pi 会话已经结束"
        case PiBridgeError.sessionEnded: "Pi 会话在发送途中结束了"
        case PiBridgeError.ackTimeout: "Pi 没有响应，请确认会话仍在运行"
        case PiBridgeError.rejected(let reason): "Pi 拒绝了这条消息：\(reason)"
        #endif
        case let error as LocalizedError: error.errorDescription ?? "\(error)"
        default: "\(error)"
        }
    }
}
