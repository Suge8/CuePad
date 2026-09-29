#if os(macOS)
import AppKit

/// 一个剪贴板条目，两种表示：
/// - `.rtfd`（仅含图片时）：按原顺序内联图片，TextEdit 等富文本目标取它；
/// - `.string`：纯文字，终端等文本目标取它，也是不认 RTFD 的应用的兜底。
/// 不并列放 `.png/.tiff`：图形应用会在其中挑图片而丢掉文字。
/// NSPasteboard 读写线程安全但未标 Sendable，故 @unchecked。
public final class PasteboardWriter: ClipboardWriting, @unchecked Sendable {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func write(_ payload: Payload) throws(DispatchError) {
        let item = NSPasteboardItem()
        item.setString(payload.plainText, forType: .string)
        if payload.hasImages { item.setData(try Self.rtfd(payload), forType: .rtfd) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]), pasteboard.string(forType: .string) == payload.plainText else {
            throw .clipboardWriteFailed
        }
        if payload.hasImages { try verifyImages(payload) }
    }

    private static func rtfd(_ payload: Payload) throws(DispatchError) -> Data {
        let document = NSMutableAttributedString()
        var index = 0
        for segment in payload.segments {
            switch segment {
            case .text(let text):
                document.append(NSAttributedString(string: text))
            case .image(let png):
                guard NSImage(data: png) != nil else { throw .clipboardWriteFailed }
                index += 1
                let wrapper = FileWrapper(regularFileWithContents: png)
                wrapper.preferredFilename = "image-\(index).png"
                document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
            }
        }
        guard let data = document.rtfd(from: NSRange(location: 0, length: document.length)) else {
            throw .clipboardWriteFailed
        }
        return data
    }

    /// 回读 RTFD，确认附件数量与位置和输入一致。
    private func verifyImages(_ payload: Payload) throws(DispatchError) {
        guard let data = pasteboard.data(forType: .rtfd),
            let document = NSAttributedString(rtfd: data, documentAttributes: nil)
        else { throw .clipboardWriteFailed }
        let expected = payload.segments.map { segment -> String in
            if case .text(let text) = segment { text } else { "\u{FFFC}" }
        }.joined()
        guard document.string == expected else { throw .clipboardWriteFailed }
    }
}
#endif
