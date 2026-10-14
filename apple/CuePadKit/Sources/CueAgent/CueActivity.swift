import CueStore
import Foundation

/// Cue 用工具时写下的那一句（`CueState.detail`，同会话的工具说明"动作 · 目标"，界面经 `PiProgress.action` 读）：
/// 自己的三个工具写成人话（建任务带标题、回想带查的词），读文件类照会话里的写法（`read · 文件名`，动词由界面翻）。
public enum CueActivity {
  /// `tool`、`arguments` 是大脑报的（`CueBrainEvent.tool`：去掉前缀的小写名字与 JSON 原文）。
  public static func detail(tool: String, arguments: String) -> String {
    let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
    func text(_ key: String) -> String? {
      (args[key] as? String)?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }
    func line(_ action: String, _ target: String? = nil) -> String {
      guard let target else { return action }
      return action + PiSessionState.detailSeparator + (target.count <= targetLimit ? target : String(target.prefix(targetLimit - 1)) + "…")
    }
    switch tool {
    case "task":
      switch text("action") {
      case "add": return line("建任务", text("title"))
      case "edit": return line("改任务")
      case "start": return line("开工")
      case "say": return line("跟会话说话")
      case "peek": return line("看进展")
      case "stop": return line("停下会话")
      case "done": return line("收尾")
      case "follow": return line("换人跟进")
      default: return line("看任务")
      }
    case "tell": return line(args["choices"] == nil ? "给你写话" : "问你")
    case "memory":
      switch text("action") {
      case "recall": return line("回想", text("query"))
      case "note", "pin": return line("记下")
      case "forget": return line("忘掉一条")
      case "remind": return line("定提醒")
      default: return line("整理记忆")
      }
    case "bash": return line(tool, text("command"))
    case "grep", "find", "glob": return line(tool == "glob" ? "find" : tool, text("pattern"))
    default: return line(tool, (text("path") ?? text("file_path")).map { URL(filePath: $0).lastPathComponent })
    }
  }

  static let targetLimit = 80
}
