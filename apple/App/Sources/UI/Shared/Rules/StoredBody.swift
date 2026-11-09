import CueText
import Foundation

nonisolated enum StoredBody {
    static func make(attachments: [String] = [], text: String, files: [DraftFile] = []) -> String {
        (attachments + [text.trimmingCharacters(in: .whitespacesAndNewlines), files.map(\.markup).joined(separator: "\n")])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
