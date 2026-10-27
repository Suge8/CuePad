#if os(macOS)
import AppKit

/// 系统剪贴板（复制不是发送，不写发送记录；复制整张卡见 `Workspace.copy`）。
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 文字与附件按原顺序：一个条目两种表示——`.string` 纯文字（文本框、终端取它，文件写文件名），有附件时另有 `.rtfd`
    /// 内联图片与文件（富文本取它：备忘录、邮件、文本编辑里粘出来是图与文件附件）。
    /// 不并列放 `.png/.tiff` 与文件网址：图形应用会在其中挑图片而丢掉文字，访达会只粘出文件。
    static func write(_ content: ClipboardContent, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        if content.hasAttachments { item.setData(try rtfd(content), forType: .rtfd) }
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
            case .file(let url, let name):
                let wrapper = try FileWrapper(url: url)
                wrapper.preferredFilename = name
                document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            }
        }
        guard let data = document.rtfd(from: NSRange(location: 0, length: document.length)) else { throw ClipboardError.writeFailed }
        return data
    }
}

/// 复制到剪贴板的内容：正文按原顺序切成的文字、图片（PNG）与文件（本机那份与显示的名字）。
nonisolated struct ClipboardContent: Sendable, Equatable {
    enum Segment: Sendable, Equatable {
        case text(String)
        case image(Data)
        case file(URL, name: String)
    }

    var segments: [Segment]

    init(_ segments: [Segment]) { self.segments = segments }

    var plainText: String {
        segments.reduce(into: "") { result, segment in
            switch segment {
            case .text(let text): result += text
            case .image: break
            case .file(_, let name): result += name
            }
        }
    }

    var hasAttachments: Bool { segments.contains { if case .text = $0 { false } else { true } } }
}

enum ClipboardError: LocalizedError {
    case writeFailed
    var errorDescription: String? { String(localized: "写入剪贴板失败") }
}
#endif
