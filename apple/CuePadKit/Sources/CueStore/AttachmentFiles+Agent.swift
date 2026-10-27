import CueText
import Foundation

/// 交给 Agent 的文件：消息里在原位置写一行"附件：文件名（绝对路径）"，路径是本机那份（`AttachmentFiles.fileURL`）；
/// 读回会话记录里你的消息时（`PiHistory`），这样的一行认回文件引用，会话页照样显示成文件；会话名与摘要里只留文件名（`namingAgentLines`）。
/// 这一行给 Agent 读，不进界面字目录（docs/i18n.md）：固定这一种中文写法，读回也只认它。
extension AttachmentFiles {
  /// 这个文件交给 Agent 的那一行；不在本机为 nil。
  public func agentLine(key: String, name: String) -> String? {
    fileURL(for: key).map { Self.label + name + "（" + $0.path(percentEncoded: false) + "）" }
  }

  /// 正文里的这一段要不要写成附件行、写成什么名字：文件按它的文件名；图片只在 `imagesAsFiles`（看不了图的会话与 Cue 的模型）时这样写，
  /// 名字是"图片.<扩展名>"，看得了图的另附原图。文字与另附的图为 nil。
  public static func agentFile(_ token: CueToken, imagesAsFiles: Bool) -> (key: String, name: String)? {
    switch token {
    case .file(let key, let name): (key, name)
    case .image(let key) where imagesAsFiles: (key, "图片." + (AttachmentKey.parts(key)?.format ?? ""))
    default: nil
    }
  }

  /// 文字里交给 Agent 的附件行换回 `[文件名](cuepad://file/<键>)`，其余照旧。只认这台设备附件目录里的。
  public func restoringAgentLines(in text: String) -> String {
    let prefix = directory.path(percentEncoded: false)
    guard text.contains(prefix) else { return text }
    return Self.mapLines(text) { line, _ in
      guard let (name, path) = Self.agentLine(line), let path, path.hasPrefix(prefix) else { return nil }
      return CueFormat.fileMarkup(key: URL(filePath: path).lastPathComponent, name: name)
    }
  }

  /// 文字里交给 Agent 的附件行只留文件名：会话名与摘要从你的话推出时都经这里（`PiSessionName.display`、`PiHistory`）。
  /// 不认目录（别的 Mac 写下的、会话自报的首条消息都可能是）；末行被截断、路径不全的也认。
  public static func namingAgentLines(in text: String) -> String {
    guard text.contains(label) else { return text }
    return mapLines(text) { line, last in agentLine(line).flatMap { $0.path != nil || last ? $0.name : nil } }
  }

  /// "附件：文件名（路径）"拆成文件名与路径；路径末段不是附件键的不认。没有收尾"）"的（截断了）路径为 nil。
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
