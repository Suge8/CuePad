import CueStore
import CueText
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
      return action + PiSessionState.detailSeparator + target.clipped(targetLimit)
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
      case "leave": return line("留给你回")
      case "done": return line("做完")
      default: return line("看任务")
      }
    case "tell": return line(args.raw["ask"] == nil ? "给你写话" : "问你")
    case "memory":
      switch args.line("action") {
      case "recall": return line("回想", args.line("query"))
      case "note", "pin": return line("记下")
      case "forget": return line("忘掉一条")
      case "remind": return line("定提醒")
      case "allow": return line("改允许清单")
      default: return line("整理记忆")
      }
    case "bash": return line(tool, args.line("command"))
    case "grep", "find", "glob": return line(tool == "glob" ? "find" : tool, args.line("pattern"))
    default: return line(tool, args.path.map { URL(filePath: $0).lastPathComponent })
    }
  }

  /// 做完的一次调用在经过清单里的一条：动到的任务按 Cue 写的引用认（与工具同一个认法），清单里点它打开那件任务；
  /// 认不出（写错了、调用失败）就照它写的引用列出，不带任务。给的是会话（say、peek、stop 带 session）就写会话名，不带任务。
  /// 对你说的话（tell）已在对话里：清单里只留首行，带着那条消息，点它跳回原处。
  public static func item(tool: String, arguments: String, failed: Bool, store: CueStore) async -> PiChatMessage.Tools.Item {
    let args = Parsed(arguments)
    let task: Card?
    if let ref = args.line("task") ?? (tool == "task" && args.line("action") == "add" ? args.line("title") : nil) {
      task = try? await CueTools(store: store).task(ref)
    } else {
      task = nil
    }
    let session = args.line("session")
    let sessionName = await session.asyncMap { ref in (try? await store.sessions(matching: ref).first?.title) ?? ref }
    let named = "「\(task?.heading ?? args.line("task") ?? args.line("title") ?? sessionName ?? "")」"
    func item(_ kind: PiChatMessage.Tools.Kind, _ target: String, message: UUID? = nil) -> PiChatMessage.Tools.Item {
      .init(kind: kind, target: target.clipped(PiChatMessage.Tools.targetLimit), failed: failed, task: task?.id, message: message)
    }
    switch tool {
    case "task":
      switch args.line("action") {
      case "add": return item(.add, "建任务\(named)")
      case "edit": return item(.other, "改\(named)")
      case "start": return item(.start, "开工\(named)")
      case "say": return item(.talk, "对\(named)说：\(args.line("text") ?? "")")
      case "peek": return task == nil && session == nil ? item(.read, "看板") : item(.read, "看\(named)的近况")
      case "stop": return item(.stop, "停下\(named)")
      case "leave": return item(.other, "\(named)留给你回")
      case "done": return item(.done, "做完\(named)")
      default: return item(.other, "task")
      }
    case "tell":
      guard let line = args.line("text"), let text = args.raw["text"] as? String else { return item(.other, "撤回一条提问") }
      let message = try? await store.latestCueMessage(saying: text)
      return item(args.raw["ask"] == nil ? .said : .ask, line, message: message?.id)
    case "memory":
      switch args.line("action") {
      case "recall": return item(.search, args.line("query") ?? "记忆")
      case "note": return item(.other, "记下：\(args.line("text") ?? "")")
      case "remind": return item(.other, "提醒：\(args.line("text") ?? "")")
      case "renew": return item(.other, "写交接备忘")
      case "allow":
        let ask = args.line("ask").map { CueAsk(rawValue: $0)?.name ?? $0 } ?? ""
        return item(.other, "允许清单：\(ask)" + ((args.raw["allowed"] as? Bool) == false ? "又要先问" : "以后不用问"))
      default: return item(.other, "整理记忆")
      }
    case "bash": return item(.command, args.line("command") ?? tool)
    case "grep", "find", "glob": return item(.search, args.line("pattern") ?? tool)
    case "read": return item(.read, args.path.map { URL(filePath: $0).lastPathComponent } ?? tool)
    default: return item(.other, tool)
    }
  }

  static let targetLimit = 80


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
