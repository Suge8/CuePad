#if os(macOS)
import AppKit

/// 系统剪贴板（复制不是发送，不写发送记录；复制整张卡见 `Workspace.copy`）。
@MainActor
enum Clipboard {
    /// 一段纯文字。
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 文字与图片按原顺序：一个条目两种表示——`.string` 纯文字（文本框、终端取它），有图时另有 `.rtfd` 内联图片（富文本取它）。
    /// 不并列放 `.png/.tiff`：图形应用会在其中挑图片而丢掉文字。
    static func write(_ content: ClipboardContent, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        if content.hasImages { item.setData(try rtfd(content), forType: .rtfd) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ClipboardError.writeFailed }
    }

    private static func rtfd(_ content: ClipboardContent) throws -> Data {
        let document = NSMutableAttributedString()
        for (index, segment) in content.segments.enumerated() {
            switch segment {
            case .text(let text):
                document.append(NSAttributedString(string: text))
            case .image(let png):
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = "image-\(index).png"
                document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            }
        }
        guard let data = document.rtfd(from: NSRange(location: 0, length: document.length)) else { throw ClipboardError.writeFailed }
        return data
    }
}

/// 复制到剪贴板的内容：正文按原顺序切成的文字与图片（PNG）。
nonisolated struct ClipboardContent: Sendable, Equatable {
    enum Segment: Sendable, Equatable {
        case text(String)
        case image(Data)
    }

    var segments: [Segment]

    init(_ segments: [Segment]) { self.segments = segments }

    var plainText: String {
        segments.reduce(into: "") { result, segment in if case .text(let text) = segment { result += text } }
    }

    var hasImages: Bool { segments.contains { if case .image = $0 { true } else { false } } }
}

enum ClipboardError: LocalizedError {
    case writeFailed
    var errorDescription: String? { "写入剪贴板失败" }
}
#endif
