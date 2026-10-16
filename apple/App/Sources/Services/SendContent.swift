import CueText
import Foundation

/// 存储格式正文按原顺序切成文字与图片引用。调用方传入的是已经填好变量的正文。
nonisolated struct SendContent: Equatable, Sendable {
    enum Segment: Equatable, Sendable {
        case text(String)
        case image(hash: String)
    }

    let segments: [Segment]

    init(stored: String) {
        segments = CueFormat.parse(stored).map { token in
            switch token {
            case .text(let text): .text(text)
            case .image(let hash): .image(hash: hash)
            }
        }
    }

    /// 去掉图片后的文字。
    var plainText: String {
        segments.reduce(into: "") { result, segment in
            if case .text(let text) = segment { result += text }
        }
    }

    var hasImages: Bool { segments.contains { if case .image = $0 { true } else { false } } }
}

#if os(macOS)
import CuePi
import CueStore

extension SendContent {
    /// 正文里的图片，按原顺序取出原图与类型交给 Agent、由它自行缩放（发给会话、交给 Cue 的大脑都用这一份）；图不在本机或认不出格式抛 `SendError.imageUnavailable`。
    func piImages(from files: AttachmentFiles) throws -> [PiImage] {
        try segments.compactMap { segment -> PiImage? in
            guard case .image(let hash) = segment else { return nil }
            let data = try files.original(hash)
            guard let mimeType = ImageFiles.mimeType(of: data) else { throw SendError.imageUnavailable(hash) }
            return PiImage(mimeType: mimeType, data: data)
        }
    }
}
#endif
