import CueStore
import Foundation

/// Cue 的一次工具调用给人看的样子，两处用：正在用时那一句（`CueState.detail`，同会话的工具说明"动作 · 目标"，界面经 `PiProgress.action` 读），
/// 做完后经过清单里的一条（`item`，与会话回答注脚的清单同一种）。自己的三个工具写成人话（建任务带标题、回想带查的词），
/// 读文件类照会话里的写法（`read · 文件名`，动词由界面翻）。
public enum CueActivity {
  /// `tool`、`arguments` 是大脑报的（`CueBrainEvent.tool`：去掉前缀的小写名字与 JSON 原文）。
  public static func detail(tool: String, arguments: String) -> String {
    let args = Parsed(arguments)
    func line(_ action: String, _ target: String? = nil) -> String {
      guard let target else { return action }
      return action + PiSessionState.detailSeparator + clip(target, targetLimit)
    }
    switch tool {
    case "task":
      switch args.line("action") {
      case "add": return line("建任务", args.line("title"))
      case "edit": return line("改任务")
      case "start": return line("开工")
      case "say": return line("跟会话说话")
      case "peek": return line("看进展")
      case "stop": return line("停下会话")
      case "done": return line("收尾")
      default: return line("看任务")
      }
    case "tell": return line(args.raw["ask"] == nil ? "给你写话" : "问你")
    case "memory":
      switch args.line("action") {
      case "recall": return line("回想", args.line("query"))
      case "note", "pin": return line("记下")
      case "forget": return line("忘掉一条")
      case "remind": return line("定提醒")
      default: return line("整理记忆")
      }
    case "bash": return line(tool, args.line("command"))
    case "grep", "find", "glob": return line(tool == "glob" ? "find" : tool, args.line("pattern"))
    default: return line(tool, args.path.map { URL(filePath: $0).lastPathComponent })
    }
  }

  /// 做完的一次调用在经过清单里的一条：动到的任务按 Cue 写的引用认（与工具同一个认法），清单里点它打开那件任务；
  /// 认不出（写错了、调用失败）就照它写的引用列出，不带任务。
  public static func item(tool: String, arguments: String, failed: Bool, store: CueStore) async -> PiChatMessage.Tools.Item {
    let args = Parsed(arguments)
    let task: Card?
    if let ref = args.line("task") ?? (tool == "task" && args.line("action") == "add" ? args.line("title") : nil) {
      task = try? await CueTools(store: store).task(ref)
    } else {
      task = nil
    }
    let named = "「\(task?.heading ?? args.line("task") ?? args.line("title") ?? "")」"
    func item(_ kind: PiChatMessage.Tools.Kind, _ target: String, of card: Card? = task) -> PiChatMessage.Tools.Item {
      .init(kind: kind, target: clip(target, kind == .said ? PiChatMessage.Tools.saidLimit : PiChatMessage.Tools.targetLimit), failed: failed, task: card?.id)
    }
    switch tool {
    case "task":
      switch args.line("action") {
      case "add": return item(.add, "建任务\(named)")
      case "edit": return item(.other, "改\(named)")
      case "start": return item(.start, "开工\(named)")
      case "say":
        guard args.raw["when"] as? String != "answer" else { return item(.talk, "替\(named)作答：\(args.line("value") ?? args.line("text") ?? "")") }
        return item(.talk, "对\(named)说：\(args.line("text") ?? "")")
      case "peek": return task == nil ? item(.read, "看板") : item(.read, "看\(named)的近况")
      case "stop": return item(.stop, "停下\(named)")
      case "done": return item(.done, "收下\(named)")
      default: return item(.other, "task")
      }
    case "tell":
      guard let text = args.line("text") else { return item(.other, "撤回一条提问") }
      return item(args.raw["ask"] == nil ? .said : .ask, text)
    case "memory":
      switch args.line("action") {
      case "recall": return item(.search, args.line("query") ?? "记忆")
      case "note": return item(.other, "记下：\(args.line("text") ?? "")")
      case "remind": return item(.other, "提醒：\(args.line("text") ?? "")")
      case "renew": return item(.other, "写交接备忘")
      default: return item(.other, "整理记忆")
      }
    case "bash": return item(.command, args.line("command") ?? tool)
    case "grep", "find", "glob": return item(.search, args.line("pattern") ?? tool)
    case "read": return item(.read, args.path.map { URL(filePath: $0).lastPathComponent } ?? tool)
    default: return item(.other, tool)
    }
  }

  static let targetLimit = 80

  private static func clip(_ text: String, _ limit: Int) -> String { text.count <= limit ? text : String(text.prefix(limit - 1)) + "…" }

  /// 大脑报的参数：JSON 对象，取各项的第一个非空行。
  private struct Parsed {
    let raw: [String: Any]

    init(_ arguments: String) { raw = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:] }

    func line(_ key: String) -> String? {
      (raw[key] as? String)?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var path: String? { line("path") ?? line("file_path") }
  }
}
