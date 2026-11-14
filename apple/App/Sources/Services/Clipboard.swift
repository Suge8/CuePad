import Foundation

/// 要复制的一条：文字与附件按先后排（存储格式正文 `CueFormat` 拆出来的那几段）。本机没有的附件由拼它的一方写成名字（`AppServices.copy`）。
nonisolated struct ClipboardContent: Sendable, Equatable {
    enum Segment: Sendable, Equatable {
        case text(String)
        case image(URL)
        case file(URL, name: String)
    }

    var segments: [Segment]

    init(_ segments: [Segment]) { self.segments = segments }

    var plainText: String {
        segments.reduce(into: "") { result, segment in
            switch segment {
            case .text(let text): result += text
            case .image: break
            case .file(_, let name): result += name
            }
        }
    }

    var hasAttachments: Bool { segments.contains { if case .text = $0 { false } else { true } } }
}
