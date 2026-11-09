import CueStore
import CueText
import Foundation

nonisolated enum Outgoing {
    static func text(of card: Card) -> String {
        text(body: card.body, values: card.variableValues)
    }

    static func text(body: String, values: [String: String]) -> String {
        CueVariables.fill(body, values: values).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
