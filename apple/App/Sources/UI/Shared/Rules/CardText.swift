import CueStore
import CueText
import Foundation

/// 卡片正文的展示摘要；标题、摘要与链接域名的规则见 `CueSummary`。
nonisolated struct CardText: Equatable, Sendable {
    /// 卡片上摘要最多几行（有图时 2 行）：Mac 墙、iPhone 两列与墙的高度估计同用。
    static let previewLines = 3

    var title: String
    /// 标题之后的第一段，供卡片与列表的摘要行。
    var preview: String
    /// 正文里的图片哈希，按出现顺序。
    var images: [String]
    /// 第一个链接的域名，卡片上当小标。
    var linkHost: String?

    init(_ body: String) {
        let summary = CueSummary(body)
        title = summary.title
        preview = summary.preview
        images = CueFormat.imageHashes(in: body)
        linkHost = summary.linkHost
    }

    /// 列表、卡片、看板里叫它什么：标题；没有文字时按有没有图写"N 张图"或"空白灵感"。全 App 只在这里定。
    var label: String { title.nonEmpty ?? (images.isEmpty ? "空白灵感" : "\(images.count) 张图") }
}

nonisolated extension Card {
    /// 列表与看板里的一行（`CardText.label`）。
    var title: String { CardText(body).label }
}

nonisolated extension String {
    /// 空串为 nil，便于 `?? 占位`。
    var nonEmpty: String? { isEmpty ? nil : self }
}
