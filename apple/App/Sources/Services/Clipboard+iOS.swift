#if os(iOS)
import CueEditor
import UIKit
import UniformTypeIdentifiers

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }

    /// 文字与图片按先后各成一个条目（备忘录、信息按条目粘出图文）；文件只写名字：手机上粘贴方多半收不了任意文件。
    /// 与 Mac 同形（Mac 的写入会失败）：调用方两端同一行。
    static func write(_ content: ClipboardContent, to pasteboard: UIPasteboard = .general) throws {
        pasteboard.setItems(content.segments.compactMap { segment -> [String: Any]? in
            switch segment {
            case .text(let text): text.isEmpty ? nil : [UTType.utf8PlainText.identifier: text]
            case .image(let url): (try? Data(contentsOf: url)).flatMap(ImageFiles.png(from:)).map { [UTType.png.identifier: $0] }
            case .file(_, let name): [UTType.utf8PlainText.identifier: name]
            }
        })
    }
}
#endif
