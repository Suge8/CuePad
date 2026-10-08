import CueText
import Foundation

/// 输入框的内容写成存储格式正文（存卡片、发给 Pi 同一份）：带上的卡片、文字、图片各成一段，段间空一行，图片之间一行一张。
nonisolated enum StoredBody {
    static func make(attachments: [String] = [], text: String, imageHashes: [String] = []) -> String {
        (attachments + [text.trimmingCharacters(in: .whitespacesAndNewlines), imageHashes.map { CueFormat.imageMarkup(id: $0) }.joined(separator: "\n")])
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
