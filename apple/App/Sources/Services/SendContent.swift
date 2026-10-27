import CueEditor
import CueText
import Foundation

/// 发给 Agent 的正文：存储格式按原顺序切成的文字、图片与文件（`CueFormat.parse`）。调用方传入的是已经填好变量的正文。
nonisolated struct SendContent: Sendable {
    private let tokens: [CueToken]

    init(stored: String) { tokens = CueFormat.parse(stored) }

    /// 只看文字：图片去掉、文件留文件名，原样拼接（不像 `CueFormat.plainText` 那样折叠空行、去首尾空白）。
    var plainText: String { tokens.map(\.shownText).joined() }

    var hasImages: Bool { tokens.contains { if case .image = $0 { true } else { false } } }

    /// 正文里的附件（图片与文件）的键，按出现顺序。
    var attachmentKeys: [String] {
        tokens.compactMap {
            switch $0 {
            case .image(let key), .file(let key, _): key
            case .text: nil
            }
        }
    }
}

#if os(macOS)
import CuePi
import CueStore

extension SendContent {
    /// 正文里的图片，按原顺序取出原图与类型交给 Agent、由它自行缩放（发给会话、交给 Cue 的大脑都用这一份）；图不在本机或认不出格式抛 `SendError.attachmentUnavailable`。
    func piImages(from files: AttachmentFiles) throws -> [PiImage] {
        try tokens.compactMap { token -> PiImage? in
            guard case .image(let key) = token else { return nil }
            let data = try files.original(key)
            guard let mimeType = ImageFiles.mimeType(of: data) else { throw SendError.attachmentUnavailable(key) }
            return PiImage(mimeType: mimeType, data: data)
        }
    }

    /// 交给 Agent 的文字：图片去掉（另作 `piImages`），文件在原处换成自成一行的"附件：文件名（路径）"（`AttachmentFiles.agentLine`）。
    /// 文件要已在本机（先 `AttachmentFiles.fetch`），不在抛 `SendError.attachmentUnavailable`。
    func agentText(from files: AttachmentFiles) throws -> String {
        var text = ""
        for (index, token) in tokens.enumerated() {
            guard case .file(let key, let name) = token else {
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

extension AttachmentFiles {
    /// 把正文里的附件都取到这台 Mac 上（发给会话、开工、斜杠命令、交给 Cue 之前）：取附件只经这一处。
    /// files-sync 的按需下载（`fetch(key)`）接上前，本机没有就抛 `SendError.attachmentUnavailable`。
    func fetch(_ content: SendContent) async throws {
        for key in content.attachmentKeys where fileURL(for: key) == nil { throw SendError.attachmentUnavailable(key) }
    }
}
#endif
