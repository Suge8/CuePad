import CueEditor
import CueStore
import CueText
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import CuePi
#endif

/// 复制不是发送，不记发送记录。
extension AppServices {
    /// 本机没有的附件只写它的名字（图片没有名字），复制照样成功。
    func copy(_ storedText: String) throws {
        let tokens = CueFormat.parse(storedText)
        #if os(macOS)
        try Clipboard.write(ClipboardContent(tokens.map { token in
            switch token {
            case .text(let text): .text(text)
            case .image(let key): store.files.fileURL(for: key).map { .image($0) } ?? .text("")
            case .file(let key, let name): store.files.fileURL(for: key).map { .file($0, name: name) } ?? .text(name)
            }
        }), to: pasteboard)
        #else
        pasteboard.setItems(tokens.compactMap { token -> [String: Any]? in
            switch token {
            case .text(let text): text.isEmpty ? nil : [UTType.utf8PlainText.identifier: text]
            case .image(let key):
                store.files.fileURL(for: key).flatMap { try? Data(contentsOf: $0) }.flatMap(ImageFiles.png(from:)).map { [UTType.png.identifier: $0] }
            case .file(_, let name): [UTType.utf8PlainText.identifier: name]
            }
        })
        #endif
    }
}

#if os(macOS)
extension CuePi.Session {
    var sendTarget: SendTarget { SendTarget(kind: .piSession, name: displayName, ref: sessionID) }
}
#endif
