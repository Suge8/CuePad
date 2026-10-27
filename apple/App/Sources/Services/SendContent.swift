import CueEditor
import CueText
import Foundation

/// 发给 Agent 的正文：存储格式按原顺序切成的文字、图片与文件（`CueFormat.parse`）。调用方传入的是已经填好变量的正文。
nonisolated struct SendContent: Sendable {
    private let tokens: [CueToken]

    init(stored: String) { tokens = CueFormat.parse(stored) }
}

#if os(macOS)
import CuePi
import CueStore

extension SendContent {
    /// 正文里的图片，按原顺序取出原图与类型交给 Agent、由它自行缩放（发给会话、交给 Cue 的大脑都用这一份）；图不在本机或认不出格式抛 `SendError.attachmentUnavailable`。
    func piImages(from files: AttachmentFiles) throws -> [PiImage] {
        try tokens.compactMap { token -> PiImage? in
            guard case .image(let key) = token else { return nil }
            guard let url = files.fileURL(for: key), let data = try? Data(contentsOf: url), let mimeType = ImageFiles.mimeType(of: data) else {
                throw SendError.attachmentUnavailable(key)
            }
            return PiImage(mimeType: mimeType, data: data)
        }
    }

    /// 交给 Agent 的文字：图片去掉（另作 `piImages`），文件在原处换成自成一行的"附件：文件名（路径）"（`AttachmentFiles.agentLine`）；
    /// `imagesAsFiles`（收不了图片的会话）时图片也这样写（`AttachmentFiles.agentFile`）。
    /// 文件要已在本机（投送执行器取齐了才执行），不在抛 `SendError.attachmentUnavailable`。
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
