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
    var label: String { title.nonEmpty ?? Self.untitled(images: images.count) }

    /// 只要名字时用它：只读到标题那一行（`CueSummary.title(of:)`），没有标题才数图片，不算摘要与链接。
    static func label(of body: String) -> String {
        CueSummary.title(of: body).nonEmpty ?? untitled(images: CueFormat.imageHashes(in: body).count)
    }

    private static func untitled(images: Int) -> String { images == 0 ? String(localized: "空白灵感") : String(localized: "\(images) 张图") }
}

nonisolated extension Card {
    var title: String { CardText.label(of: body) }
}

nonisolated extension String {
    /// 空串为 nil，便于 `?? 占位`。
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// 项目页的发送标记文案。项目名与会话名相同，写"已发过"而不是重复项目名。
nonisolated enum SendCopy {
    static var sameProject: String { String(localized: "已发过") }
}

nonisolated extension SendTarget {
    /// 卡上"发给过谁"写的名字：只有 Agent 会话，非会话目标（`SendTargetKind.mac`）不当去处。
    var shownName: String? { kind == .known(.piSession) ? name : nil }
}
