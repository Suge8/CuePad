import CueStore
import CueText
import Foundation

/// 卡片（或其中选中的部分）发出去（发送、复制、分享）的正文：变量已填，去掉首尾空白。
nonisolated enum Outgoing {
    static func text(of card: Card) -> String {
        text(body: card.body, values: card.variableValues)
    }

    static func text(body: String, values: [String: String]) -> String {
        CueVariables.fill(body, values: values).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
