import CueText
import Foundation

/// 卡片正文的展示摘要；标题与摘要的规则见 `CueSummary`。
nonisolated struct CardText: Equatable, Sendable {
    var title: String
    /// 标题之后的文字，供卡片与列表的摘要行。
    var preview: String
    /// 正文里的图片哈希，按出现顺序。
    var images: [String]

    init(_ body: String) {
        let summary = CueSummary(body)
        title = summary.title
        preview = summary.preview
        images = CueFormat.imageHashes(in: body)
    }
}
