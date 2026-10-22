import CueStore
import CueText
import Foundation

/// Cue 的一次工具调用给人看的样子，两处用：正在用时那一句（`CueState.detail`，界面经 `PiProgress.action` 读），
/// 做完后经过清单里的一条（`item`，与会话回答注脚的清单同一种）。自己的三个工具写成人话、说清对象（对哪件活、哪个会话，建任务带标题、回想带查的词），
/// 读文件类照会话里的写法（`read · 文件名`，动词由界面翻）。
public enum CueActivity {
  /// 任务那个工具各动作的说法，正在用时那一句（`detail`）与做完后清单里那一条（`item`）同一张表：`named` 是认出的对象（`Named.quoted`），
  /// `board`：看的是看板（没指哪件活）。认不出的动作为 nil。
  static func phrase(_ action: String?, _ named: String, board: Bool) -> (kind: PiChatMessage.Tools.Kind, text: String)? {
    switch action {
    case "add": (.add, "建任务\(named)")
    case "edit": (.other, "改\(named)")
    case "start": (.start, "开工\(named)")
    case "say": (.talk, "对\(named)说")
    case "peek": (.read, board ? "看板" : "看\(named)的近况")
    case "stop": (.stop, "停下\(named)")
    case "leave": (.other, "\(named)留给你回")
    case "done": (.done, "做完\(named)")
    default: nil
    }
  }

  /// 调用开始时认一次对象（`Named`），存在这次调用上，正在用时那一句与做完后那一条都用它，不再查第二次库。
  public static func named(tool: String, arguments: String, store: CueStore) async -> Named {
    await Named(Parsed(arguments), tool: tool, store: store)
  }

  /// 正在用时那一句：Cue 自己的工具写成"动作「对象」"（与经过清单里那一条同一个说法，`phrase`），读文件类照会话里的写法"工具 · 目标"。
  /// `tool`、`arguments` 是大脑报的（`CueBrainEvent.tool`：去掉前缀的小写名字与 JSON 原文）。
  public static func detail(tool: String, arguments: String, named: Named) -> String {
    let args = Parsed(arguments)
    func line(_ action: String, _ target: String? = nil) -> String {
      guard let target else { return action }
      return action + PiSessionState.detailSeparator + target.clipped(targetLimit)
    }
    switch tool {
    case "task":
      return phrase(args.line("action"), named.quoted, board: args.board)?.text ?? "看任务"
    case "tell": return args.raw["ask"] == nil ? "给你写话" : "问你"
    case "memory":
      switch args.line("action") {
      case "recall": return line("回想", args.line("query"))
      case "zoom": return "翻记忆"
      case "note", "pin": return "记下"
      case "forget": return "忘掉一条"
      case "remind": return "定提醒"
      case "allow": return "改允许清单"
      default: return "用记忆"
      }
    case "bash": return line(tool, args.line("command"))
    case "grep", "find", "glob": return line(tool == "glob" ? "find" : tool, args.line("pattern"))
    default: return line(tool, args.path.map { URL(filePath: $0).lastPathComponent })
    }
  }

  /// 做完的一次调用在经过清单里的一条：动到的任务与会话是开始时认出的（`named`），清单里点它打开那件任务；
  /// 认不出（写错了、调用失败）就照它写的引用列出，不带任务。给的是会话就写会话名，不带任务。
  /// 对你说的话（tell）已在对话里：清单里只留首行，带着那条消息，点它跳回原处。记忆的序号是 Cue 内部的身份，不写给人看。
  public static func item(tool: String, arguments: String, named: Named, failed: Bool, store: CueStore) async -> PiChatMessage.Tools.Item {
    let args = Parsed(arguments)
    func item(_ kind: PiChatMessage.Tools.Kind, _ target: String, message: UUID? = nil) -> PiChatMessage.Tools.Item {
      .init(kind: kind, target: target.clipped(PiChatMessage.Tools.targetLimit), failed: failed, task: named.task, message: message)
    }
    switch tool {
    case "task":
      let action = args.line("action")
      guard let said = phrase(action, named.quoted, board: args.board) else { return item(.other, "task") }
      return item(said.kind, action == "say" ? "\(said.text)：\(args.line("text") ?? "")" : said.text)
    case "tell":
      guard let line = args.line("text"), let text = args.raw["text"] as? String else { return item(.other, "撤回一条提问") }
      let message = try? await store.latestCueMessage(saying: text)
      return item(args.raw["ask"] == nil ? .said : .ask, line, message: message?.id)
    case "memory":
      switch args.line("action") {
      case "recall": return item(.search, args.line("query") ?? "记忆")
      case "note": return item(.other, "记下：\(args.line("text") ?? "")")
      case "remind": return item(.other, "提醒：\(args.line("text") ?? "")")
      case "zoom": return item(.read, "翻记忆")
      case "allow":
        let ask = args.line("ask").map { CueAsk(rawValue: $0)?.name ?? $0 } ?? ""
        return item(.other, "允许清单：\(ask)" + ((args.raw["allowed"] as? Bool) == false ? "又要先问" : "以后不用问"))
      case "forget": return item(.other, "忘掉一条记忆")
      case "pin": return item(.other, (args.raw["pinned"] as? Bool) == false ? "一条记忆不再一直记着" : "一条记忆一直记着")
      default: return item(.other, "memory")
      }
    case "bash": return item(.command, args.line("command") ?? tool)
    case "grep", "find", "glob": return item(.search, args.line("pattern") ?? tool)
    case "read": return item(.read, args.path.map { URL(filePath: $0).lastPathComponent } ?? tool)
    default: return item(.other, tool)
    }
  }

  /// Cue 写的那件活或那个会话，与工具同一个认法（session 写成任务的编号也认作那件任务）；`quoted` 是给人看的"「名字」"，认不出照它写的。
  public struct Named: Sendable {
    public let task: UUID?
    public let quoted: String

    init(_ args: Parsed, tool: String, store: CueStore) async {
      let tools = CueTools(store: store)
      var task: Card?, sessionName: String?
      if let ref = args.line("task") ?? (tool == "task" && args.line("action") == "add" ? args.line("title") : nil) {
        task = try? await tools.task(ref)
      } else if let session = args.line("session") {
        switch try? await tools.sessionRef(session) {
        case .session(let found): sessionName = found.title
        case .task(let card): task = card
        case nil: sessionName = session
        }
      }
      self.task = task?.id
      quoted = "「\(task?.heading ?? args.line("task") ?? args.line("title") ?? sessionName ?? "")」"
    }
  }

  static let targetLimit = 80

  /// 大脑报的参数：JSON 对象，取各项的第一个非空行。
  struct Parsed {
    let raw: [String: Any]

    init(_ arguments: String) { raw = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:] }

    func line(_ key: String) -> String? {
      (raw[key] as? String)?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var path: String? { line("path") ?? line("file_path") }
    /// 看的是看板：没指哪件活、哪个会话。
    var board: Bool { line("task") == nil && line("session") == nil }
  }
}
