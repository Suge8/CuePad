import CueText
import Foundation

/// 发给 Agent 的正文：存储格式按原顺序切成的文字与图片（`CueFormat.parse`）。调用方传入的是已经填好变量的正文。
nonisolated struct SendContent: Sendable {
    private let tokens: [CueToken]

    init(stored: String) { tokens = CueFormat.parse(stored) }

    /// 去掉图片后的文字，原样拼接（不像 `CueFormat.plainText` 那样折叠空行、去首尾空白）。
    var plainText: String {
        tokens.reduce(into: "") { result, token in
            if case .text(let text) = token { result += text }
        }
    }

    var hasImages: Bool { tokens.contains { if case .image = $0 { true } else { false } } }
}

#if os(macOS)
import CuePi
import CueStore

extension SendContent {
    /// 正文里的图片，按原顺序取出原图与类型交给 Agent、由它自行缩放（发给会话、交给 Cue 的大脑都用这一份）；图不在本机或认不出格式抛 `SendError.imageUnavailable`。
    func piImages(from files: AttachmentFiles) throws -> [PiImage] {
        try tokens.compactMap { token -> PiImage? in
            guard case .image(let hash) = token else { return nil }
            let data = try files.original(hash)
            guard let mimeType = ImageFiles.mimeType(of: data) else { throw SendError.imageUnavailable(hash) }
            return PiImage(mimeType: mimeType, data: data)
        }
    }
}
#endif
