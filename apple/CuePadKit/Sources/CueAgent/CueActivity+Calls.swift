import CueStore
import CueText
import Foundation

/// 认 Cue 的一次工具调用（两种说法给谁看见 `CueActivity` 头注释）：正在用时碰到的那一处（`step`，界面按按钮动词表写）或没碰哪一处时那一句（`detail`），
/// 与做完后经过清单里那一条（`item`：给 Cue 自己看的说法写在 `target`，碰到的那一处另记在 `name`、`task`、`session`，与 `step` 同一对）。
/// 读文件类照会话里的写法（`read · 文件名`，动词由界面翻）。
extension CueActivity {
  /// 任务那个工具的动作是哪一种；认不出的动作为 nil。
  static func kind(_ action: String?) -> PiChatMessage.Tools.Kind? {
    switch action {
    case "add": .add
    case "edit": .edit
    case "start": .start
    case "say": .talk
    case "peek": .read
    case "stop": .stop
    case "leave": .leave
    case "done": .done
    default: nil
    }
  }

  /// Cue 自己的说法（`Tools.Item.target`，只进它的上下文 `CueView`）：跟它的工具名走，不跟按钮。`named` 是认出的对象（`Named.quoted`），
  /// `board`：看的是看板（没指哪件活）。
  static func cueWords(_ action: String?, _ named: String, board: Bool) -> String? {
    switch action {
    case "add": "建任务\(named)"
    case "edit": "改\(named)"
    case "start": "开工\(named)"
    case "say": "对\(named)说"
    case "peek": board ? "看板" : "看\(named)的近况"
    case "stop": "停下\(named)"
    case "leave": "\(named)留给你回"
    case "done": "做完\(named)"
    default: nil
    }
  }

  /// 调用开始时认一次对象（`Named`），存在这次调用上，正在用时那一句与做完后那一条都用它，不再查第二次库。
  public static func named(tool: String, arguments: String, store: CueStore) async -> Named {
    await Named(Parsed(arguments), tool: tool, store: store)
  }

  /// 正在用时碰到的那一处：任务那个工具指了哪一处时有（与做完后那一条的 `name`、`task`、`session` 同一对）；看板（没指哪一处）、认不出的动作为 nil。
  public static func step(tool: String, arguments: String, named: Named) -> Touch? {
    let args = Parsed(arguments)
    guard tool == "task", let kind = kind(args.line("action")), let name = named.name else { return nil }
    return Touch(kind: kind, name: name, task: named.task, session: named.session)
  }

  /// 正在用时没碰哪一处（`step` 为 nil）的那一句：看板、记忆、对你说，读文件类照会话里的写法"工具 · 目标"。
  /// `tool`、`arguments` 是大脑报的（`CueBrainEvent.tool`：去掉前缀的小写名字与 JSON 原文）。
  public static func detail(tool: String, arguments: String) -> String {
    let args = Parsed(arguments)
    func line(_ action: String, _ target: String? = nil) -> String {
      guard let target else { return action }
      return action + PiSessionState.detailSeparator + target.clipped(targetLimit)
    }
    switch tool {
    case "task": return args.line("action") == "peek" && args.board ? "看板" : "看任务"
    case "tell": return args.raw["ask"] == nil ? "给你写话" : "问你"
    case "memory":
      switch args.line("action") {
      case "recall": return line("回想", args.line("query"))
      case "zoom": return "翻记忆"
      case "note", "pin": return "记下"
      case "forget": return "忘掉一条"
      case "remind": return "定提醒"
      default: return "用记忆"
      }
    case "bash": return line(tool, args.line("command"))
    case "grep", "find", "glob": return line(tool == "glob" ? "find" : tool, args.line("pattern"))
    default: return line(tool, args.path.map { URL(filePath: $0).lastPathComponent })
    }
  }

  /// 做完的一次调用在经过清单里的一条：动到的任务与会话是开始时认出的（`named`，新建的那件开始时还没有，做成了再认，`Named.added`），记在这一条上；
  /// 认不出（写错了、调用失败）就照它写的引用，不带任务与会话。
  /// 对你说的话（tell）已在对话里：清单里只留首行。记忆的序号是 Cue 内部的身份，不写给人看。
  public static func item(tool: String, arguments: String, named: Named, failed: Bool, store: CueStore) async -> PiChatMessage.Tools.Item {
    let args = Parsed(arguments)
    func item(_ kind: PiChatMessage.Tools.Kind, _ target: String, at place: Named? = nil) -> PiChatMessage.Tools.Item {
      .init(
        kind: kind, target: target.clipped(PiChatMessage.Tools.targetLimit), failed: failed, task: place?.task, name: place?.name,
        session: place?.session)
    }
    switch tool {
    case "task":
      let action = args.line("action")
      guard let kind = kind(action), let words = cueWords(action, named.quoted, board: args.board) else { return item(.other, "task") }
      let place = action == "add" && !failed ? await named.added(args, store: store) : named
      return item(kind, action == "say" ? "\(words)：\(args.line("text") ?? "")" : words, at: place)
    case "tell":
      guard let line = args.line("text") else { return item(.other, "撤回一条提问") }
      return item(args.raw["ask"] == nil ? .said : .ask, line)
    case "memory":
      switch args.line("action") {
      case "recall": return item(.search, args.line("query") ?? "记忆")
      case "note": return item(.other, "记下：\(args.line("text") ?? "")")
      case "remind": return item(.other, "提醒：\(args.line("text") ?? "")")
      case "zoom": return item(.read, "翻记忆")
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

  /// Cue 写的那件活或那个会话，与工具同一个认法（session 写成任务的编号也认作那件任务）：`name` 是它叫什么，认不出照它写的；没指哪一处为 nil。
  public struct Named: Sendable {
    public let task: UUID?
    /// 是会话时（`PiSessionState.id`）
    public let session: UUID?
    public let name: String?
    /// "「名字」"
    var quoted: String { "「\(name ?? "")」" }

    private init(task: UUID?, session: UUID?, name: String?) {
      self.task = task
      self.session = session
      self.name = name
    }

    /// 开始时认：add 要建的那件还没有，只照标题叫它（按标题去找会认成同名的旧任务，比如早做完的那件）。
    init(_ args: Parsed, tool: String, store: CueStore) async {
      let tools = CueTools(store: store)
      var task: Card?, found: PiSessionState?, sessionRef: String?
      if let ref = args.line("task") {
        task = try? await tools.task(ref)
      } else if let session = args.line("session") {
        switch try? await tools.sessionRef(session) {
        case .session(let state): found = state
        case .task(let card): task = card
        case nil: sessionRef = session
        }
      }
      self.task = task?.id
      session = found?.id
      name = task?.heading ?? args.line("task") ?? args.line("title") ?? found?.title ?? sessionRef
    }

    /// add 做成后它建的那件，或认作同一件、没再建的那件（`CueTools.openTopTasks`）：没做完的同名顶层任务里后建的；会话照开始时认的。
    func added(_ args: Parsed, store: CueStore) async -> Named {
      guard let title = args.line("title"), let card = try? await CueTools(store: store).openTopTasks(titled: title).first else { return self }
      return Named(task: card.id, session: session, name: card.heading)
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
