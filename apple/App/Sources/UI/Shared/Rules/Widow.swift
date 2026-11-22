import Foundation

nonisolated enum Widow {
    static func joined(_ text: String) -> String {
        guard let space = text.lastIndex(of: " ") else { return text }
        let before = text[..<space].reversed().prefix(while: isWordChar), after = text[text.index(after: space)...]
        guard isWord(before), after.allSatisfy(isWordChar), isWord(after) else { return text }
        return text.replacingCharacters(in: space...space, with: "\u{00A0}")
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isASCII && !c.isWhitespace }

    private static func isWord(_ s: some Sequence<Character>) -> Bool { s.contains { $0.isLetter || $0.isNumber } }
}
