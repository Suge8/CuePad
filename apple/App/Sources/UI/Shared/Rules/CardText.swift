import CueText
import Foundation

/// 卡片正文的展示摘要。卡片没有标题字段：标题 = 正文首个非空行（去掉 `#` 标题前缀），图片与分隔线不算。
nonisolated struct CardText: Equatable, Sendable {
    var title: String
    /// 标题之后的文字，行间以空格连接，供卡片与列表的摘要行。
    var preview: String
    var blockCount: Int
    /// 正文里的图片哈希，按出现顺序。
    var images: [String]

    private static let previewLimit = 240

    init(_ body: String) {
        let lines = CueSegments.contentLines(body)
        title = lines.first.map(Self.stripHeading) ?? ""
        preview = String(lines.dropFirst().joined(separator: " ").prefix(Self.previewLimit))
        blockCount = CueSegments.parse(body).filter { !CueSegments.trim($0.text).isEmpty }.count
        images = CueFormat.parse(body).compactMap { token in
            if case .image(let hash) = token { hash } else { nil }
        }
    }

    private static func stripHeading(_ line: String) -> String {
        let trimmed = line.drop { $0 == "#" }
        return trimmed.count < line.count ? trimmed.trimmingCharacters(in: .whitespaces) : line
    }
}
