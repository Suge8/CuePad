import CueStore
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

nonisolated extension Card {
    /// 列表与看板里的一行：正文第一行；正文还空着时写"无标题"。
    var title: String { CueSummary(body).title.nonEmpty ?? "无标题" }
}

nonisolated extension String {
    /// 空串为 nil，便于 `?? 占位`。
    var nonEmpty: String? { isEmpty ? nil : self }
}
