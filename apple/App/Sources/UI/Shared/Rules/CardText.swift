import CueStore
import CueText
import Foundation

nonisolated struct CardText: Equatable, Sendable {
    /// Mac 墙、iPhone 两列与墙的高度估计同用。
    static let previewLines = 3

    var title: String
    var preview: String
    var attachments: [String]
    var images: [String]
    var files: Int
    var linkHost: String?

    init(_ body: String) {
        let summary = CueSummary(body, inline: MarkdownBlock.plainText)
        title = summary.title
        preview = summary.preview
        attachments = CueFormat.attachmentKeys(in: body)
        images = attachments.filter(AttachmentKey.isImage)
        files = attachments.count - images.count
        linkHost = summary.linkHost
    }

    /// 全 App 只在这里定。
    var label: String { title.nonEmpty ?? Self.untitled(attachments) }

    /// 只读到标题那一行（`CueSummary.title(of:)`），没有标题才数附件，不算摘要与链接。
    static func label(of body: String) -> String {
        MarkdownBlock.plainText(CueSummary.title(of: body)).nonEmpty ?? untitled(CueFormat.attachmentKeys(in: body))
    }

    private static func untitled(_ attachments: [String]) -> String {
        if attachments.isEmpty { return String(localized: "空白灵感") }
        return attachments.allSatisfy(AttachmentKey.isImage) ? String(localized: "\(attachments.count) 张图") : String(localized: "\(attachments.count) 个附件")
    }
}

nonisolated extension Card {
    var title: String { CardText.label(of: body) }

    /// 任务的标题为空时是会话名，随会话改名变（从看板上的会话建的任务正文为空，`CueStore.adoptSession`）。名字的唯一事实源仍是任务标题，这里不另存。
    func title(session: String?) -> String {
        guard isTask, heading.isEmpty, let session = session?.nonEmpty else { return title }
        return session
    }
}

nonisolated extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

nonisolated enum SendCopy {
    static var sameProject: String { String(localized: "已发过") }
}

nonisolated extension SendTarget {
    var shownName: String? { kind == .known(.piSession) ? name : nil }
}
