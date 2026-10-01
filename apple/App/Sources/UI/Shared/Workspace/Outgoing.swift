import CueStore
import CueText
import Foundation

/// 卡片发出去（发送、复制、分享）的正文：变量已填、编号已排。
nonisolated enum Outgoing {
    static func text(of card: Card) -> String {
        text(body: card.body, values: card.variableValues, numbering: card.numbering)
    }

    static func text(body: String, values: [String: String], numbering: Open<CueNumbering>) -> String {
        CueSegments.format(CueVariables.fill(body, values: values), numbering: numbering.known ?? .none)
    }
}
