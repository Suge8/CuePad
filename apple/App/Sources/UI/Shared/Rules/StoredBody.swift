import CueText
import Foundation

/// 输入框的内容写成存储格式正文（存卡片、发给 Pi 同一份）：带上的卡片、文字、附件各成一段，段间空一行，附件一行一个。
nonisolated enum StoredBody {
    static func make(attachments: [String] = [], text: String, files: [DraftFile] = []) -> String {
        (attachments + [text.trimmingCharacters(in: .whitespacesAndNewlines), files.map(\.markup).joined(separator: "\n")])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
