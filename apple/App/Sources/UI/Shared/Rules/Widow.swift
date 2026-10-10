import Foundation

/// 段落末尾不留单独一个英文单词（排版里的"孤字"）：中文行里夹的英文原因常在最后一个词上折行，下一行只剩"long"。
/// 把最后两个英文单词之间的空格换成不断行空格，要换行就两个词一起换。只动末尾是两个英文单词的段落。
nonisolated enum Widow {
    static func joined(_ text: String) -> String {
        guard let space = text.lastIndex(of: " ") else { return text }
        let before = text[..<space].last, after = text[text.index(after: space)...]
        guard let before, isLatin(before), !after.isEmpty, after.allSatisfy(isLatin) else { return text }
        return text.replacingCharacters(in: space...space, with: "\u{00A0}")
    }

    /// 英文单词里的字：字母、数字与常见的词内标点。
    private static func isLatin(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "'-.:/_".contains(c))
    }
}
