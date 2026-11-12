import CueText
import Foundation

/// 这一行给 Agent 读，不进界面字目录（apple/App/Strings/AGENTS.md）：固定这一种中文写法，读回也只认它。
extension AttachmentFiles {
  public func agentLine(key: String, name: String) -> String? {
    fileURL(for: key).map { Self.label + name + "（" + $0.path(percentEncoded: false) + "）" }
  }

  public static func agentFile(_ token: CueToken, imagesAsFiles: Bool) -> (key: String, name: String)? {
    switch token {
    case .file(let key, let name): (key, name)
    case .image(let key) where imagesAsFiles: (key, "图片." + (AttachmentKey.parts(key)?.format ?? ""))
    default: nil
    }
  }

  public func restoringAgentLines(in text: String) -> String {
    let prefix = directory.path(percentEncoded: false)
    guard text.contains(prefix) else { return text }
    return Self.mapLines(text) { line, _ in
      guard let (name, path) = Self.agentLine(line), let path, path.hasPrefix(prefix) else { return nil }
      return CueFormat.fileMarkup(key: URL(filePath: path).lastPathComponent, name: name)
    }
  }

  /// 不认目录（别的 Mac 写下的、会话自报的首条消息都可能是）；末行被截断、路径不全的也认。
  public static func namingAgentLines(in text: String) -> String {
    guard text.contains(label) else { return text }
    return mapLines(text) { line, last in agentLine(line).flatMap { $0.path != nil || last ? $0.name : nil } }
  }

  private static func agentLine(_ line: Substring) -> (name: String, path: String?)? {
    guard line.hasPrefix(label), let open = line.range(of: "（/", options: .backwards) else { return nil }
    let name = String(line[line.index(line.startIndex, offsetBy: label.count)..<open.lowerBound])
    guard !name.isEmpty else { return nil }
    guard line.hasSuffix("）") else { return (name, nil) }
    let path = String(line[line.index(after: open.lowerBound)..<line.index(before: line.endIndex)])
    return AttachmentKey.isValid(URL(filePath: path).lastPathComponent) ? (name, path) : nil
  }

  private static func mapLines(_ text: String, _ transform: (Substring, _ last: Bool) -> String?) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    return lines.enumerated().map { index, line in transform(line, index == lines.count - 1) ?? String(line) }.joined(separator: "\n")
  }

  private static let label = "附件："
}
