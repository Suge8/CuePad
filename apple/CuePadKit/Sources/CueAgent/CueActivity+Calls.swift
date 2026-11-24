import CueStore
import CueText
import Foundation

extension CueActivity {
  public static func settlesStop(tool: String, arguments: String) -> Bool {
    tool == "task" && Parsed(arguments).action?.settlesStop == true
  }

  public static func named(tool: String, arguments: String, store: CueStore) async -> Named {
    await Named(Parsed(arguments), tool: tool, store: store)
  }

  public static func step(tool: String, arguments: String, named: Named) -> Touch? {
    let args = Parsed(arguments)
    guard tool == "task", let kind = args.action?.kind, let name = named.name else { return nil }
    return Touch(kind: kind, name: name, task: named.task, session: named.session)
  }

  public static func detail(tool: String, arguments: String) -> String {
    let args = Parsed(arguments)
    func line(_ action: String, _ target: String? = nil) -> String {
      guard let target else { return action }
      return action + SessionState.detailSeparator + target.clipped(targetLimit)
    }
    switch tool {
    case "task": return args.line("action") == "peek" && args.board ? "看板" : "看任务"
    case "tell": return "给你写话"
    case "memory":
      switch args.line("action") {
      case "recall": return line("回想", args.line("query"))
      case "zoom": return "翻记忆"
      case "note", "pin": return "记下"
      case "forget": return "忘掉一条"
      case "remind": return "定时"
      default: return "用记忆"
      }
    case "setup": return setupWords(args)
    case "bash": return line(tool, args.line("command"))
    case "grep", "find", "glob": return line(tool == "glob" ? "find" : tool, args.line("pattern"))
    default: return line(tool, args.path.map { URL(filePath: $0).lastPathComponent })
    }
  }

  public static func item(tool: String, arguments: String, named: Named, failed: Bool, store: CueStore) async -> ChatMessage.Tools.Item {
    let args = Parsed(arguments)
    func item(_ kind: ChatMessage.Tools.Kind, _ target: String, at place: Named? = nil) -> ChatMessage.Tools.Item {
      .init(
        kind: kind, target: target.clipped(ChatMessage.Tools.targetLimit), failed: failed, task: place?.task, name: place?.name,
        session: place?.session)
    }
    switch tool {
    case "task":
      let action = args.action
      guard let words = action?.words(named.quoted, board: args.board, starts: args.raw["start"] as? Bool == true) else { return item(.other, "task") }
      guard let kind = action?.kind else { return item(.other, words) }
      let place = action == .add && !failed ? await named.added(args, store: store) : named
      return item(kind, action == .say ? "\(words)：\(args.line("text") ?? "")" : words, at: place)
    case "tell": return item(.said, args.line("text") ?? "")
    case "memory":
      switch args.line("action") {
      case "recall": return item(.search, args.line("query") ?? "记忆")
      case "note":
        let replaced = (args.raw["replaces"] as? [Any])?.count ?? 0
        return item(.other, (replaced > 0 ? "记下（换掉 \(replaced) 条）：" : "记下：") + (args.line("text") ?? ""))
      case "remind":
        let text = args.line("text") ?? ""
        var task: UUID?
        if !failed, let ref = args.line("task") { task = try? await CueReferences(store: store).task(ref).id }
        return .init(kind: .schedule, target: "定时：\(text)".clipped(ChatMessage.Tools.targetLimit), failed: failed, task: task, name: text)
      case "zoom": return item(.read, "翻记忆")
      case "forget": return item(.other, "忘掉一条记忆")
      case "pin": return item(.other, (args.raw["pinned"] as? Bool) == false ? "一条记忆取消重点" : "一条记忆标为重点")
      default: return item(.other, "memory")
      }
    case "setup": return item(args.line("action") == "look" ? .read : .other, setupWords(args))
    case "bash": return item(.command, args.line("command") ?? tool)
    case "grep", "find", "glob": return item(.search, args.line("pattern") ?? tool)
    case "read": return item(.read, args.path.map { URL(filePath: $0).lastPathComponent } ?? tool)
    default: return item(.other, tool)
    }
  }

  static func setupWords(_ args: Parsed) -> String {
    switch args.line("action") {
    case "look": return "看设置" + (args.line("part").map { SessionState.detailSeparator + $0 } ?? "")
    case "set":
      let changed = ["agent", "model", "effort", "name"].compactMap { key in args.line(key).map { "\(key)=\($0)" } }
        + [(args.raw["fast"] as? Bool).map { "fast=\($0)" }].compactMap(\.self)
      return "改大脑" + (changed.isEmpty ? "" : "：" + changed.joined(separator: " "))
    case "project": return ((args.raw["new"] as? Bool) == true ? "建项目" : "改项目") + "「\(args.line("project") ?? "")」"
    case "tidy": return "整理技能与规则"
    default: return "用设置"
    }
  }

  public struct Named: Sendable {
    public let task: UUID?
    public let session: UUID?
    public let name: String?
    var quoted: String { "「\(name ?? "")」" }

    private init(task: UUID?, session: UUID?, name: String?) {
      self.task = task
      self.session = session
      self.name = name
    }

    init(_ args: Parsed, tool: String, store: CueStore) async {
      var task: Card?, found: SessionState?
      switch try? await CueReferences(store: store).place(Args(args.raw)) {
      case .session(let state): found = state
      case .task(let card): task = card
      case nil: break
      }
      self.task = task?.id
      session = found?.id
      let written = args.line("task") ?? args.line("session")
      name = task?.heading ?? (found == nil ? args.line("task") : nil) ?? args.line("title") ?? found?.title ?? written
    }

    func added(_ args: Parsed, store: CueStore) async -> Named {
      let refs = CueReferences(store: store)
      guard let title = Args(args.raw).string("title")?.trimmingCharacters(in: .whitespacesAndNewlines),
        let project = try? await refs.addProject(Args(args.raw)),
        let card = try? await refs.openTopTask(titled: title, in: project)
      else { return self }
      return Named(task: card.id, session: session, name: card.heading)
    }
  }

  static let targetLimit = 80

  struct Parsed {
    let raw: [String: Any]

    init(_ arguments: String) { raw = Args.given((try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]) }

    func line(_ key: String) -> String? {
      (raw[key] as? String)?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    var action: TaskAction? { line("action").flatMap(TaskAction.init(rawValue:)) }

    var path: String? { line("path") ?? line("file_path") }
    var board: Bool { line("task") == nil && line("session") == nil }
  }
}
