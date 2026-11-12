import Foundation

/// 一次调用有两种说法，各给一拨读者，不合成一份：给人看的（这里，动词与按钮同名，会改）；给 Cue 看的（`Tools.Item.target`，由 `CueActivity.item` 写）跟工具名与系统提示走，改了等于改提示词，要做前后评测（apple/scripts/cue-eval.sh）。
/// 认调用、写这两句的在 CueAgent（`CueActivity+Calls`，只在 Mac 上有），界面各端读这边。
public enum CueActivity {
  /// `.edit` 在 Cue 的一轮里是改任务（会话里的改文件不读这张表）。
  public static func verb(_ kind: ChatMessage.Tools.Kind) -> String? {
    switch kind {
    case .read: String(localized: "查看")
    case .talk: String(localized: "发给")
    case .add: String(localized: "建任务")
    case .start: String(localized: "启动")
    case .stop: String(localized: "收掉")
    case .done: String(localized: "做完")
    case .leave: String(localized: "留给你")
    case .schedule: String(localized: "新建 定时")
    case .edit: String(localized: "修改")
    case .command, .search, .other, .said, .ask: nil
    }
  }

  static let weight: [ChatMessage.Tools.Kind] = [.done, .stop, .talk, .start, .add, .edit, .read]

  public static func outcomeRank(_ kind: ChatMessage.Tools.Kind) -> Int {
    [.done, .stop, .leave, .talk, .start, .add, .schedule, .edit, .read].firstIndex(of: kind) ?? .max
  }

  public struct Touch: Codable, Equatable, Sendable {
    public var kind: ChatMessage.Tools.Kind
    public let name: String
    public let task: UUID?
    public let session: UUID?

    public init(kind: ChatMessage.Tools.Kind, name: String, task: UUID? = nil, session: UUID? = nil) {
      self.kind = kind
      self.name = name
      self.task = task
      self.session = session
    }
  }

  public static func line(_ touch: Touch) -> String { "\(verb(touch.kind) ?? "") \(touch.name)" }

  public static func touches(_ tools: ChatMessage.Tools?) -> [Touch] {
    var touches: [Touch] = []
    for item in tools?.items ?? [] where !item.failed {
      guard let name = item.name, item.kind.ownLine || weight.contains(item.kind) else { continue }
      let touch = Touch(kind: item.kind, name: name, task: item.task, session: item.session)
      guard let index = touches.firstIndex(where: { $0.same(touch) }) else {
        touches.append(touch)
        continue
      }
      if rank(item.kind) < rank(touches[index].kind) { touches[index].kind = item.kind }
    }
    return touches
  }

  private static func rank(_ kind: ChatMessage.Tools.Kind) -> Int { weight.firstIndex(of: kind) ?? weight.count }
}

extension ChatMessage.Tools.Kind {
  var ownLine: Bool { self == .leave || self == .schedule }
}

extension CueActivity.Touch {
  func same(_ other: Self) -> Bool {
    guard kind.ownLine == other.kind.ownLine, !kind.ownLine || kind == other.kind else { return false }
    if task != nil || other.task != nil { return task == other.task }
    if session != nil || other.session != nil { return session == other.session }
    return name == other.name
  }
}
