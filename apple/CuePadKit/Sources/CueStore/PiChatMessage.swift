import CueText
import Foundation

public enum PiChatRole: String, Sendable, CaseIterable {
  /// 你说的（含 CuePad 替你发的）；扩展投进来的机器消息不算，那是 `machine`
  case user
  /// Pi 一轮做完的回答
  case pi
  /// 一行系统记录（`PiNotice`：压缩、这一轮被停下或被你拒绝）；不是谁说的话。设置类条目（换模型、改强度、改名）终端的对话里没有，这里也没有
  case system
  /// 扩展投进会话的机器消息（`PiEnvelope`：FireCode 交回子代理结果、审查结论、观察员的提醒……），正文是信封原文；
  /// 它开始一轮，但不是你说的话（不算提问）
  case machine
  /// 你在 CuePad 里答了会话的提问（`PiAnswer`）：不在会话文件里，由执行作答的那台 Mac 在作答成功时写下（`CueStore.finishDelivery`），
  /// 是"你答了什么"的唯一记录。正文是答案（`PiAnswerValue.label`），`question` 是当时问的；`at` 是答的那一刻，对话按它插进去
  case answer
}

/// 会话对话里的一条消息（同步表 `piMessages`，Mac 写、各端只读，只追加；读会话文件的规则变了之后重读，已写过的消息的正文与工具活动会更新）。
///
/// 唯一来源是 Pi 的会话文件：Mac 读会话文件写出（在线会话随文件追加跟上，更早的按需补写），记录 id 由会话 id 与
/// 文件里那一条的 id 算出，重读不重复。一轮一条 Pi 消息：这一轮最后的回答；中途调工具时说的话、思考与工具输出都不同步，
/// 只记这一轮的经过（`tools`：工具调用的分类计数、调用与中途说的话按先后的一份紧凑清单，不含工具输出）和从你说话起做了多久
/// （界面写"跑了 12 步 · 改了 3 个文件 · 2 分钟"）。还在跑的这一轮到目前为止的经过在会话记录上（`PiRecap.pendingTools`）。
public struct PiChatMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Pi 自己的会话 id（同 `PiSessionState.sessionID`）
  public var sessionID: String
  /// 在会话里的先后：会话文件里那一条的序号（文件只追加，重读不变）。对话按它升序排；同一条里出的两行（被停下时说了一半的话与"已停止"）
  /// 序号相同，按说话人排：Agent 说的在系统行前
  public var seq: Int64
  public var role: Open<PiChatRole>
  /// 正文。你的消息是 CuePad 正文格式（`CueFormat`：文字，附件是 `![](cuepad://file/<键>)` 与 `[文件名](cuepad://file/<键>)`，与投送请求的 content 同一种），
  /// Pi 的回答与系统行是纯文字。文字至多 `PiChatMessage.textLimit` 个字符，超出截断并以省略号结尾（图片引用不计、不截）
  public var text: String
  /// 这条消息的时间（会话文件里的时间戳）
  public var at: Date
  /// Pi 消息：这一轮的工具活动（没调工具为 nil）；你的消息为 nil
  public var tools: Tools?
  /// Pi 消息：这一轮从哪一刻开始（你说话或机器消息到达）；与 `at` 之差是做了多久。你的消息为 nil
  public var roundStartedAt: Date?
  /// 你的作答（`answer`）：当时问的是什么（问题原文）；别的为 nil
  public var question: String?
  /// 你的作答是确认框的是或否时，各端按自己的语言写的那句（`PiAnswerValue.shown`）；选项与填的字照原文，为 nil。界面读 `shown`
  public var shownText: ShownText?
  /// 你的消息：它是 CuePad 的哪条投送请求送进去的（扩展把请求 id 写进会话文件里那条消息）；在终端里直接打的为 nil。
  /// 界面据此把那条投送请求的气泡换成这条消息：对话里出现 `deliveryID == request.id` 的消息时不再显示请求气泡
  public var deliveryID: UUID?
  public var createdAt: Date
  public var modifiedAt: Date

  /// 单条正文上限（字符）。实测近 7 天 60 个会话的 2172 条回答：中位 399、p99 2649、最长 6195 字符；
  /// 8000 字符全部容下，最多约 24KB（加密后仍远低于 CloudKit 单条记录 1MB），超长的通常是整段代码或日志，Mac 上看全文
  public static let textLimit = 8_000

  public init(
    sessionID: String, entryID: String, seq: Int64, role: PiChatRole, text: String, at: Date, tools: Tools? = nil,
    roundStartedAt: Date? = nil, deliveryID: UUID? = nil, question: String? = nil, shownText: ShownText? = nil
  ) {
    id = Self.recordID(sessionID: sessionID, entryID: entryID)
    self.sessionID = sessionID
    self.seq = seq
    self.role = .known(role)
    self.text = role == .machine ? PiEnvelope.parse(text).map { PiEnvelope.clipped($0, limit: Self.textLimit) } ?? Self.clipped(text) : Self.clipped(text)
    self.at = at
    self.tools = tools
    self.roundStartedAt = roundStartedAt
    self.deliveryID = deliveryID
    self.question = question
    self.shownText = shownText
    createdAt = .stamp
    modifiedAt = createdAt
  }

  /// 系统行的种类；不是系统行、或别的版本写的不认识的为 nil。
  public var notice: PiNotice? { role == .known(.system) ? PiNotice(rawValue: text) : nil }

  /// 文字超过上限时截断，图片引用原样保留：切坏引用会让图片变成一段乱码。
  private static func clipped(_ text: String) -> String {
    guard text.count > textLimit else { return text }
    let tokens = CueFormat.parse(text)
    let length = tokens.reduce(0) { total, token in
      if case .text(let piece) = token { return total + piece.count }
      return total
    }
    guard length > textLimit else { return text }
    var room = textLimit - 1
    var kept: [CueToken] = []
    for token in tokens {
      guard case .text(let piece) = token else {
        kept.append(token)
        continue
      }
      guard room > 0 else { continue }
      kept.append(.text(String(piece.prefix(room))))
      room -= piece.count
      if room <= 0 { kept.append(.text("…")) }
    }
    return CueFormat.serialize(kept)
  }

  /// 会话文件里一条（你的消息、或一轮最后的回答）对应的记录 id，任何时候重读都一样。
  public static func recordID(sessionID: String, entryID: String) -> UUID {
    DeterministicID.uuid("pi-message/\(sessionID)/\(entryID)")
  }
}

extension PiChatMessage: Record {
  static let table = Table.piMessages
  static let columns = [
    "id", "sessionID", "seq", "role", "text", "at", "tools", "roundStartedAt", "deliveryID", "createdAt", "modifiedAt", "question", "shownText",
  ]
  var bindings: [any SQLBindable] {
    [id, sessionID, seq, role.rawValue, text, at, tools?.stored, roundStartedAt, deliveryID, createdAt, modifiedAt, question, shownText?.stored]
  }
  init(row: Row) {
    id = row.uuid(0)
    sessionID = row.text(1)
    seq = row.int(2)
    role = Open(rawValue: row.text(3))
    text = row.text(4)
    at = row.date(5)
    tools = row.textOrNil(6).flatMap(Tools.init(stored:))
    roundStartedAt = row.dateOrNil(7)
    deliveryID = row.uuidOrNil(8)
    createdAt = row.date(9)
    modifiedAt = row.date(10)
    question = row.textOrNil(11)
    shownText = row.textOrNil(12).flatMap(ShownText.init(stored:))
  }

  /// 给人看的正文，这台设备的语言。
  public var shown: String { shownText?.text ?? text }
}

extension PiChatMessage {
  /// 这里只判断有正证据的 Cue 来源；不在集合里的投送仍可能来源未确认。
  public func saidByCue(_ cueSent: Set<UUID>) -> Bool { role == .known(.user) && deliveryID.map(cueSent.contains) == true }

  public func source(in sources: [UUID: MessageSource]) -> MessageSource {
    guard let deliveryID else { return .user }
    return sources[deliveryID] ?? .unconfirmed
  }
}

extension PiChatMessage {
  /// 一轮的经过：调了几次工具（失败的也算，读、改同一个文件只算一次；界面上的"跑了 N 步"）和一份按先后的清单——
  /// 每次调用一条（自己标成败），中途说的每段话也一条（`said`，不是调用）；最后那段话是回答，不在清单里。
  /// Agent 会话的由 Mac 从会话文件汇出，Cue 的由值班的管理器从这一轮的调用汇出（`CueActivity`）；同步记录里存为 JSON（加密字段）。
  public struct Tools: StoredJSON, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
      case edit, command, read, search, other
      /// 中途说的一段话（调工具前后说的"先看看…""测试挂了，查一下"；Cue 用 tell 对你说的）：`target` 是那段话
      case said
      /// Cue 的动作：对会话说话、开工、建任务、做完、停下会话、问你、把会话留给你回（`CueLeft`）、新建定时（`CueMemoryLine`）；碰到的那一处在 `Item.name` 等几项上
      case talk, start, add, done, stop, ask, leave, schedule

      /// 落了结果的一步（改文件与 Cue 的动作）：清单里总列上，标题行逐类写个数。
      public var acts: Bool {
        switch self {
        case .edit, .talk, .start, .add, .done, .stop, .ask, .leave, .schedule: true
        case .command, .read, .search, .other, .said: false
        }
      }

      /// 只是看了看的一步（读、搜、跑命令）；其余都算动过手（Cue 留给你回、记一笔也是）。
      /// 更新的版本加的种类旧版本解不出：整份经过读成 nil（`StoredJSON`），那一轮只是不显示经过，消息照读。
      public var looks: Bool { self == .read || self == .search || self == .command }
    }

    public struct Item: Codable, Equatable, Sendable {
      public var kind: Kind
      /// 文件路径（相对工作目录）、命令的第一个非空行、搜索的模式或工具名；说的话是那段话（至多 `saidLimit` 个字符）。
      /// Cue 的一步是它自己的说法，只进它的上下文（`CueActivity.item`），界面不读
      public var target: String
      public var failed: Bool
      /// 改文件：新增、删除的行数；算不出为 nil
      public var added: Int?
      public var removed: Int?
      /// Cue 动到的任务：清单里点这一条打开它
      public var task: UUID?
      /// Cue 碰到的那一处叫什么（任务的标题、会话名，认不出时照它写的引用）；没指哪一处（看板、记忆）为 nil。Cue 页这一轮的经过读它（`CueActivity.touches`）
      public var name: String?
      /// Cue 碰到的会话（`PiSessionState.id`）：点了进会话
      public var session: UUID?

      public init(
        kind: Kind, target: String, failed: Bool = false, added: Int? = nil, removed: Int? = nil, task: UUID? = nil, name: String? = nil,
        session: UUID? = nil
      ) {
        self.kind = kind
        self.target = target
        self.failed = failed
        self.added = added
        self.removed = removed
        self.task = task
        self.name = name
        self.session = session
      }
    }

    /// 调用数（与清单的行同一口径；说的话不算）
    public var steps: Int
    /// 清单，按发生先后。落了结果的（`Kind.acts`）与说的话总在里面；其余调用至多列到 `itemLimit` 条，超出的只进计数
    public var items: [Item]

    static let itemLimit = 30
    /// 清单里一条调用的目标至多这么多字符
    public static let targetLimit = 120
    /// 一段说的话至多这么多字符：够读出它在想什么。进行中这一轮的清单每做完一步就随会话记录整份上传一次，不让长话把它撑大
    public static let saidLimit = 200

    public init(steps: Int = 0, items: [Item] = []) {
      self.steps = steps
      self.items = items
    }

    /// 记下一条：说的话照列、不算一步；做完的一次调用计一步，清单没满或它落了结果（`Kind.acts`）就列上。
    public mutating func record(_ item: Item) {
      guard item.kind != .said else { return items.append(item) }
      steps += 1
      if item.kind.acts || items.count(where: { $0.kind != .said }) < Self.itemLimit { items.append(item) }
    }
  }
}
