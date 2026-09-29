import Foundation

/// `{{变量}}`：名称为非空且不含 `{` `}` 换行的文本。
public enum CueVariables {
    /// 提取变量名，重复变量只保留第一次出现的位置。
    public static func names(in text: String) -> [String] {
        var seen = Set<String>()
        return matches(in: text, within: nil).compactMap { match in
            let name = String(decoding: match.name, as: UTF16.self)
            return seen.insert(name).inserted ? name : nil
        }
    }

    /// 替换已填写的变量值；未提供或留空的变量保留原始占位符（空串不是有效填充）。
    public static func fill(_ text: String, values: [String: String]) -> String {
        let units = Array(text.utf16)
        var result = ""
        var cursor = 0
        for match in matches(in: text, within: nil) {
            let name = String(decoding: match.name, as: UTF16.self)
            guard let value = values[name], !value.isEmpty else { continue }
            result += String(decoding: units[cursor..<match.range.location], as: UTF16.self) + value
            cursor = NSMaxRange(match.range)
        }
        return result + String(decoding: units[cursor...], as: UTF16.self)
    }

    /// `range`（UTF-16，通常是被编辑的段落）内所有变量的范围，含花括号；高亮用。
    public static func ranges(in text: String, within range: NSRange) -> [NSRange] {
        matches(in: text, within: range).map(\.range)
    }

    private struct Match {
        var range: NSRange
        var name: ArraySlice<UInt16>
    }

    private static func matches(in text: String, within range: NSRange?) -> [Match] {
        let utf16 = text.utf16
        let lower = range?.location ?? 0
        let upper = range.map { min(NSMaxRange($0), utf16.count) } ?? utf16.count
        guard upper - lower >= 5 else { return [] }
        let start = utf16.index(utf16.startIndex, offsetBy: lower)
        let units = Array(utf16[start..<utf16.index(start, offsetBy: upper - lower)])
        let open: UInt16 = 0x7B, close: UInt16 = 0x7D, newline: UInt16 = 0x0A
        var found: [Match] = []
        var i = 0
        while i + 1 < units.count {
            guard units[i] == open, units[i + 1] == open else { i += 1; continue }
            var j = i + 2
            while j < units.count, units[j] != open, units[j] != close, units[j] != newline { j += 1 }
            if j > i + 2, j + 1 < units.count, units[j] == close, units[j + 1] == close {
                found.append(Match(range: NSRange(location: lower + i, length: j + 2 - i), name: units[(i + 2)..<j]))
                i = j + 2
            } else {
                i += 1
            }
        }
        return found
    }
}
