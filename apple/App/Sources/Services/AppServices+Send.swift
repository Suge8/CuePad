import CueStore
import CueText
import Foundation
#if os(macOS)
import CueBridge
#endif

/// 复制不是发送，不记发送记录。
extension AppServices {
    /// 本机没有的附件只写它的名字（图片没有名字），复制照样成功。
    func copy(_ storedText: String) throws {
        let content = ClipboardContent(CueFormat.parse(storedText).map { token in
            switch token {
            case .text(let text): .text(text)
            case .image(let key): store.files.fileURL(for: key).map { .image($0) } ?? .text("")
            case .file(let key, let name): store.files.fileURL(for: key).map { .file($0, name: name) } ?? .text(name)
            }
        })
        try Clipboard.write(content, to: pasteboard)
    }
}

#if os(macOS)
extension CueBridge.Session {
    var sendTarget: SendTarget { SendTarget(kind: .piSession, name: displayName, ref: sessionID) }
}
#endif
