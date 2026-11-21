import CueEditor
import CueText
import Foundation

nonisolated struct SendContent: Sendable {
    private let tokens: [CueToken]

    init(stored: String) { tokens = CueFormat.parse(stored) }
}

#if os(macOS)
import CueBridge
import CueStore

extension SendContent {
    func messageImages(from files: AttachmentFiles) throws -> [MessageImage] {
        try tokens.compactMap { token -> MessageImage? in
            guard case .image(let key) = token else { return nil }
            guard let url = files.fileURL(for: key), let data = try? Data(contentsOf: url), let mimeType = ImageFiles.mimeType(of: data) else {
                throw SendError.attachmentUnavailable(key)
            }
            return MessageImage(mimeType: mimeType, data: data)
        }
    }

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
