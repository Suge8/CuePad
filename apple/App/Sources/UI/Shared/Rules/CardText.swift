import CueStore
import CueText
import Foundation

nonisolated struct CardText: Equatable, Sendable {
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

    var label: String { title.nonEmpty ?? Self.untitled(attachments) }

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

    func title(session: String?) -> String {
        guard isTask, heading.isEmpty, let session = session?.nonEmpty else { return title }
        return session
    }
}

nonisolated extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
