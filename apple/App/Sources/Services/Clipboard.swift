import Foundation

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
