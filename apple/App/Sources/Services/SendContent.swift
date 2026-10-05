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
        var segments: [Segment] = []
        func appendText(_ text: String) {
            if case .text(let previous)? = segments.last {
                segments[segments.count - 1] = .text(previous + text)
            } else {
                segments.append(.text(text))
            }
        }
        for token in CueFormat.parse(stored) {
            switch token {
            case .text(let text): appendText(text)
            case .split: appendText(CueFormat.splitMarker)
            case .image(let hash): segments.append(.image(hash: hash))
            }
        }
        self.segments = segments
    }

    /// 去掉图片后的文字。
    var plainText: String {
        segments.reduce(into: "") { result, segment in
            if case .text(let text) = segment { result += text }
        }
    }

    var hasImages: Bool { segments.contains { if case .image = $0 { true } else { false } } }
}
