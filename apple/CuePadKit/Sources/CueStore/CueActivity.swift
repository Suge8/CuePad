import Foundation

/// Cue 的一次工具调用给人看的样子。一次调用有两种说法，各给一拨读者，不合成一份：
/// - 给人看的（这里）：动作词与按钮同名（`verb`：查看、发给、新建、修改、开始、停止、完成、留给你），配碰到的那一处（`Tools.Item.name`）。
///   Cue 页这一轮的经过（`touches`）与正在跑的那一步（`CueState.step`：页头那句、对话里在跑那一行、Mac 的"运行情况"）都按这张表写（`line`）。
/// - 给 Cue 看的（`Tools.Item.target`，`CueActivity.item` 写）：跟它的工具名走（开工、做完、对「X」说：…），同 WORDS 里"做完"是 Cue 的说法，
///   只进它换新后的对话视图（`CueView`）。
/// 界面的动词跟按钮走、会改；Cue 的说法跟工具与系统提示走，改了等于改提示词，要做前后评测（docs/cue-eval.md）。所以两份各管各的。
/// 认调用、写这两句的在 CueAgent（`CueActivity+Calls`）：那边只在 Mac 上有，界面各端读这边。
public enum CueActivity {
  /// 按钮同名的动作词；不碰任务与会话的种类（读文件、命令、记忆）没有。`.edit` 在 Cue 的一轮里是改任务（会话里的改文件不读这张表）。
  public static func verb(_ kind: PiChatMessage.Tools.Kind) -> String? {
    switch kind {
    case .read: String(localized: "查看")
    case .talk: String(localized: "发给")
    case .add: String(localized: "新建")
    case .start: String(localized: "开始")
    case .stop: String(localized: "停止")
    case .done: String(localized: "完成")
    case .leave: String(localized: "留给你")
    case .edit: String(localized: "修改")
    case .command, .search, .other, .said, .ask: nil
    }
  }

  /// 同一处一轮里做了几件事时留哪一件：越靠前越要紧。留给你不在里面，另算一行（`touches`）。
  static let weight: [PiChatMessage.Tools.Kind] = [.done, .stop, .talk, .start, .add, .edit, .read]

  /// 碰到的一处与对它做的事：这一轮的经过里的一行（最要紧的那个动作，`touches`），或正在跑的那一步（`CueState.step`）。
  public struct Touch: Codable, Equatable, Sendable {
    public var kind: PiChatMessage.Tools.Kind
    public let name: String
    /// 是任务时有：点了开任务气泡
    public let task: UUID?
    /// 是会话时有：点了进会话
    public let session: UUID?

    public init(kind: PiChatMessage.Tools.Kind, name: String, task: UUID? = nil, session: UUID? = nil) {
      self.kind = kind
      self.name = name
      self.task = task
      self.session = session
    }
  }

  /// 一处写成一句："发给 登录回调超时"（页头、Mac 的"运行情况"；对话里的行把动词与名字分两种墨，见 `CueTrace`）。
  public static func line(_ touch: Touch) -> String { "\(verb(touch.kind) ?? "") \(touch.name)" }

  /// 这一轮碰到的各处，按第一次碰到的先后，一处一行：只算碰到任务与会话、做成了的动作（看板、记忆、搜索、命令、读文件不算）；
  /// 同一处做了几件事只留最要紧的（`weight`）；留给你另算一行，排在它出现的地方。
  public static func touches(_ tools: PiChatMessage.Tools?) -> [Touch] {
    var touches: [Touch] = []
    for item in tools?.items ?? [] where !item.failed {
      guard let name = item.name, item.kind == .leave || weight.contains(item.kind) else { continue }
      let touch = Touch(kind: item.kind, name: name, task: item.task, session: item.session)
      guard let index = touches.firstIndex(where: { $0.same(touch) }) else {
        touches.append(touch)
        continue
      }
      if rank(item.kind) < rank(touches[index].kind) { touches[index].kind = item.kind }
    }
    return touches
  }

  private static func rank(_ kind: PiChatMessage.Tools.Kind) -> Int { weight.firstIndex(of: kind) ?? weight.count }
}

extension CueActivity.Touch {
  /// 同一处、同一类（留给你与别的动作分开算）：认得出的按任务、会话，认不出的按名字。
  func same(_ other: Self) -> Bool {
    guard (kind == .leave) == (other.kind == .leave) else { return false }
    if task != nil || other.task != nil { return task == other.task }
    if session != nil || other.session != nil { return session == other.session }
    return name == other.name
  }
}
