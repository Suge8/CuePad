#if os(macOS)
import AppKit
import CueEditor

/// 系统剪贴板（复制不是发送，不写发送记录；复制整张卡见 `Workspace.copy`）。
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 文字与附件按原顺序：一个条目两种表示——`.string` 纯文字（文本框、终端取它，文件写文件名），有附件时另有 `.rtfd`
    /// 内联图片与文件（富文本取它：备忘录、邮件、文本编辑里粘出来是图与文件附件）。
    /// `.rtfd` 按需生成（`RichText`）：复制这一下不读附件，粘贴方真要富文本时才读，几百 MB 的文件不在复制时进内存。
    /// 不并列放 `.png/.tiff` 与文件网址：图形应用会在其中挑图片而丢掉文字，访达会只粘出文件。
    static func write(_ content: ClipboardContent, to pasteboard: NSPasteboard = .general) throws {
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        if content.hasAttachments { item.setDataProvider(RichText(content), forTypes: [.rtfd]) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { throw ClipboardError.writeFailed }
    }

    /// 粘贴方要 `.rtfd` 时才读附件、拼出富文本（剪贴板条目持有它，直到下一次复制）。图片转成 PNG（富文本里各应用都认），
    /// 读不出的只留文字。
    private final class RichText: NSObject, NSPasteboardItemDataProvider {
        /// 附件按先后装进富文本，合计不过这么多字节，装不下的文件只写名字：实测一份超过 256MiB 的数据剪贴板就交不出去
        /// （250MiB 的文件拼出 263MB 照常粘出，260MiB 的拼出约 274MB 时粘贴方拿到的是空），整份富文本连同文字都没了。
        static let budget = 240_000_000

        let content: ClipboardContent

        init(_ content: ClipboardContent) { self.content = content }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            let document = NSMutableAttributedString()
            var room = Self.budget
            for (index, segment) in content.segments.enumerated() {
                if case .image(let url) = segment, Self.take(url, from: &room) == false { continue }
                if case .file(let url, let name) = segment, Self.take(url, from: &room) == false {
                    document.append(NSAttributedString(string: name))
                    continue
                }
                let wrapper: FileWrapper?
                switch segment {
                case .text(let text):
                    document.append(NSAttributedString(string: text))
                    continue
                case .image(let url):
                    wrapper = (try? Data(contentsOf: url)).flatMap(ImageFiles.png(from:)).map(FileWrapper.init(regularFileWithContents:))
                    wrapper?.preferredFilename = "image-\(index).png"
                case .file(let url, let name):
                    wrapper = try? FileWrapper(url: url)
                    wrapper?.preferredFilename = name
                    if wrapper == nil { document.append(NSAttributedString(string: name)) }
                }
                if let wrapper { document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))) }
            }
            if let data = document.rtfd(from: NSRange(location: 0, length: document.length)) { item.setData(data, forType: type) }
        }

        /// 这份文件还装得下就从余量里扣掉。
        private static func take(_ url: URL, from room: inout Int) -> Bool {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= room else { return false }
            room -= size
            return true
        }
    }
}

/// 复制到剪贴板的内容：正文按原顺序切成的文字、图片与文件（本机那份；文件带显示的名字）。本机没有的附件只是文字（它的名字）。
nonisolated struct ClipboardContent: Sendable, Equatable {
    enum Segment: Sendable, Equatable {
        case text(String)
        case image(URL)
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
