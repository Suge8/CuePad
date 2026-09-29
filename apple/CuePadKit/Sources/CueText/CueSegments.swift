import Foundation

public struct CueSegment: Equatable, Sendable {
    public var text: String
}

/// 按分隔线把存储格式正文切段，并生成复制排版。
public enum CueSegments {
    /// 分段不含分隔线本身，段内空白（空行、行尾空格）原样保留。
    public static func parse(_ stored: String) -> [CueSegment] {
        var segments: [CueSegment] = []
        var current: [String] = []
        for line in stored.components(separatedBy: "\n") {
            if CueFormat.isMarkerLine(line) {
                segments.append(CueSegment(text: current.joined(separator: "\n")))
                current = []
            } else {
                current.append(line)
            }
        }
        segments.append(CueSegment(text: current.joined(separator: "\n")))
        return segments
    }

    /// 卡片标题的唯一规则：非空、不是分隔线，且除图片引用（存储格式的 `![](…)` 或运行时的 U+FFFC）外还有文字。
    /// 卡片列表、界面与编辑器的标题行装饰都以此判定。
    public static func isTitleLine(_ line: String) -> Bool { !titleText(of: line).isEmpty }

    /// 正文里全部标题行的文字（去掉图片引用，空白折成单个空格），按出现顺序。
    /// 卡片标题是第一行，摘要是其后各行。
    public static func contentLines(_ stored: String) -> [String] {
        stored.components(separatedBy: "\n").map(titleText(of:)).filter { !$0.isEmpty }
    }

    /// 卡片标题 = 首个标题行；没有标题行返回空串。
    public static func firstContentLine(_ stored: String) -> String {
        for line in stored.components(separatedBy: "\n") {
            let text = titleText(of: line)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func titleText(of line: String) -> String {
        guard !CueFormat.isMarkerLine(line) else { return "" }
        let text = CueFormat.parse(line).compactMap { token -> String? in
            if case .text(let text) = token { text } else { nil }
        }.joined()
        let object = String(UnicodeScalar(CueFormat.objectCharacter)!)
        return text.replacingOccurrences(of: object, with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 去掉段首尾空行与两端空白，段内格式不动。
    public static func trim(_ segment: String) -> String {
        segment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 复制排版（确定性规则）：每段 trim、空段丢弃；单段不加头；
    /// 开启编号时注入 `## <编号>` 段头，否则段间用 `---` 分隔。
    public static func format(_ stored: String, numbering: CueNumbering) -> String {
        let segments = parse(stored).map { trim($0.text) }.filter { !$0.isEmpty }
        if segments.count <= 1 { return segments.first ?? "" }
        let parts = segments.enumerated().map { index, segment in
            if numbering != .none { return "## \(numbering.label(forSegment: index))\n\(segment)" }
            return index == 0 ? segment : "---\n\n\(segment)"
        }
        return parts.joined(separator: "\n\n")
    }
}
