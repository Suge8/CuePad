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

    /// 首个非分隔线的非空行；卡片预览/标题兜底用。
    public static func firstContentLine(_ stored: String) -> String {
        stored.components(separatedBy: "\n").first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !CueFormat.isMarkerLine($0)
        } ?? ""
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
