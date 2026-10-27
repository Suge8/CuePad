import CueText
import Foundation

/// 交给 Agent 的文件：消息里在原位置写一行"附件：文件名（绝对路径）"，路径是本机那份（`AttachmentFiles.fileURL`）；
/// 读回会话记录里你的消息时（`PiHistory`），这样的一行认回文件引用，会话页照样显示成文件。
/// 认的是结构不是字：标签到第一个"："或": "为止，行尾括号里是附件目录下的一个键——用哪种界面语言发的都认得回来。
extension AttachmentFiles {
  /// 这个文件交给 Agent 的那一行；不在本机为 nil。
  public func agentLine(key: String, name: String) -> String? {
    fileURL(for: key).map { String(localized: "附件：\(name)（\($0.path(percentEncoded: false))）") }
  }

  /// 文字里交给 Agent 的附件行换回 `[文件名](cuepad://file/<键>)`，其余照旧。
  public func restoringAgentLines(in text: String) -> String {
    let prefix = directory.path(percentEncoded: false)
    guard text.contains(prefix) else { return text }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { restored($0, prefix: prefix) ?? String($0) }.joined(separator: "\n")
  }

  private func restored(_ line: Substring, prefix: String) -> String? {
    guard let close = line.last, close == "）" || close == ")", let path = line.range(of: prefix, options: .backwards),
      path.lowerBound > line.startIndex
    else { return nil }
    let open = line.index(before: path.lowerBound)
    let key = String(line[path.upperBound..<line.index(before: line.endIndex)])
    guard line[open] == "（" || line[open] == "(", AttachmentKey.isValid(key) else { return nil }
    let head = line[..<open]
    guard let label = head.range(of: "：") ?? head.range(of: ": ") else { return nil }
    return CueFormat.fileMarkup(key: key, name: head[label.upperBound...].trimmingCharacters(in: .whitespaces))
  }
}
