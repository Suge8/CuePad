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
    /// 正文里引用的附件（图片与文件）的键，按出现顺序（`CueFormat.attachmentKeys`）：有没有附件、带几个都按它。
    var attachments: [String]
    /// 其中的图片：卡片、列表与搜索的预览显示第一张。
    var images: [String]
    /// 其余（不是图片的文件）有几个：预览里看不见，卡片上另标（`AttachmentMark`）。
    var files: Int
    /// 第一个链接的域名，卡片上当小标。
    var linkHost: String?

    init(_ body: String) {
        let summary = CueSummary(body)
        title = summary.title
        preview = summary.preview
        attachments = CueFormat.attachmentKeys(in: body)
        images = attachments.filter(AttachmentKey.isImage)
        files = attachments.count - images.count
        linkHost = summary.linkHost
    }

    /// 列表、卡片、看板里叫它什么：标题；没有文字时按带了什么写"N 张图""N 个附件"或"空白灵感"。全 App 只在这里定。
    var label: String { title.nonEmpty ?? Self.untitled(attachments) }

    /// 只要名字时用它：只读到标题那一行（`CueSummary.title(of:)`），没有标题才数附件，不算摘要与链接。
    static func label(of body: String) -> String {
        CueSummary.title(of: body).nonEmpty ?? untitled(CueFormat.attachmentKeys(in: body))
    }

    private static func untitled(_ attachments: [String]) -> String {
        if attachments.isEmpty { return String(localized: "空白灵感") }
        return attachments.allSatisfy(AttachmentKey.isImage) ? String(localized: "\(attachments.count) 张图") : String(localized: "\(attachments.count) 个附件")
    }
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
