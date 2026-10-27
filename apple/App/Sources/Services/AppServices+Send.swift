import CueEditor
import CueStore
import CueText
import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import CuePi
#endif

/// 复制：正文解析 → 放进系统剪贴板。复制不是发送，不记发送记录；发给 Agent 见 `Workspace.speak`。
extension AppServices {
    /// 复制正文（存储格式，变量已填）：文字与附件按原顺序放进系统剪贴板，本机没有的附件只写它的名字（图片没有名字），复制照样成功。
    /// Mac 上本机有的图片与文件作为附件带上（纯文字那份写文件名）；手机上图片带上、文件写文件名。
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
        // 每段文字、每张图片各一个条目，按原顺序：目标应用能取到哪些由它决定
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
extension CuePi.PiSession {
    /// 发送记录与投送请求里指这个会话的目标（`ref` 是 Pi 自己的会话 id）。
    var sendTarget: SendTarget { SendTarget(kind: .piSession, name: displayName, ref: sessionID) }
}
#endif
