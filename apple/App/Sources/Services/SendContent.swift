import CueEditor
import CueText
import Foundation

/// 调用方传入的是已经填好变量的正文。
nonisolated struct SendContent: Sendable {
    private let tokens: [CueToken]

    init(stored: String) { tokens = CueFormat.parse(stored) }
}

#if os(macOS)
import CuePi
import CueStore

extension SendContent {
    /// 原图与类型交给 Agent、由它自行缩放；图不在本机或认不出格式抛 `SendError.attachmentUnavailable`。
    func piImages(from files: AttachmentFiles) throws -> [MessageImage] {
        try tokens.compactMap { token -> MessageImage? in
            guard case .image(let key) = token else { return nil }
            guard let url = files.fileURL(for: key), let data = try? Data(contentsOf: url), let mimeType = ImageFiles.mimeType(of: data) else {
                throw SendError.attachmentUnavailable(key)
            }
            return MessageImage(mimeType: mimeType, data: data)
        }
    }

    /// `imagesAsFiles`（收不了图片的会话）时图片也按文件写。文件要已在本机（投送执行器取齐了才执行），不在抛 `SendError.attachmentUnavailable`。
    func agentText(from files: AttachmentFiles, imagesAsFiles: Bool = false) throws -> String {
        var text = ""
        for (index, token) in tokens.enumerated() {
            guard let (key, name) = AttachmentFiles.agentFile(token, imagesAsFiles: imagesAsFiles) else {
                text += token.shownText
                continue
            }
            guard let line = files.agentLine(key: key, name: name) else { throw SendError.attachmentUnavailable(key) }
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += line
            if let next = tokens.dropFirst(index + 1).first, !next.shownText.hasPrefix("\n") { text += "\n" }
        }
        return text
    }
}
#endif
