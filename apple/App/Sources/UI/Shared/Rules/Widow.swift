import Foundation

/// 段落末尾不留单独一个英文单词（排版里的"孤字"）：中文行里夹的英文原因常在最后一个词上折行，下一行只剩"long"。
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
