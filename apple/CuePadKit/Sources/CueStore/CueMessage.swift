import CueText
import Foundation


/// 不认识的（旧版本写下的交接备忘 `handoff`、更新版本的新种类）界面不列、不交给大脑。
public enum CueAuthor: String, Sendable, CaseIterable {
  case you
  case cue
  /// Cue 自己醒来那一轮的经过（不推送，Cue 页每轮一行旁注）：没有正文，带着它为什么醒（`wake`）与做了什么（`tools`）；旧版本还写过带正文的动态，只读
  case note
  /// 你发起的一轮的经过（`tools`，没有正文）：排在这一轮开始的位置，这一轮说的话与结果都在它之后（`CueStore.recordCueRound`）。
  case round
}

/// Cue 对话唯一的事实源（不读运行时的会话文件）。写入后只有提问的结束（`answer`、`answeredAt`）与送达（`deliveredAt`）会变；一轮的经过那一行随这一轮做到哪改它的清单。
/// 提问只有一个状态：`answeredAt` 为空是开着，有值是结束了（`CueQuestionEnd`）；结束了不再变，只有你在 Cue 页开口收起的 Cue 放得回。
public struct CueMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var author: Open<CueAuthor>
  /// 正文（`CueFormat`）；你的消息可带图片引用。CuePad 代写的（`shownText`）是读出来时按这台设备的语言写的那一份，库里不存（列留空）。
  public var text: String
  public var shownText: ShownText? = nil
  /// 选项只由 `CueAsk.choices` 在写入时按 `asked` 写出，Cue 不能自拟；写下就不再变，卡片与通知照它显示。
  public var choices: [String]?
  /// 提问的类别与范围（明文、同步，写入时定下）。
  public var asked: CueAsked?
  /// 提问要做的动作与依据的规矩（`CueAsking`；用户内容，加密同步）。
  public var askAction: String?
  public var askRule: String?
  /// Cue 点名要你看的图，按它给的先后（`CueShot.checked`）：提问的是回答它必须看的，做完的结果是证明结论的最终成果（`CueStore.finishTask`）。
  /// 卡片、通知与全屏预览只读它，没点名的没有图。看什么是用户内容，加密同步；列与同步字段沿用最初只有提问时的名字 askShots（同步表不改已有列）。
  public var shots: [CueShot] = []
  public var ask: CueAsk? { asked?.ask.known }
  public func allowsFromNowOn(_ answer: String?) -> Bool {
    guard ask != nil, let choices, choices.count > 1 else { return false }
    return answer == choices[1]
  }
  public var asking: CueAsking? { CueAsking(stored: ask, action: askAction, rule: askRule) }
  /// 要提示你（推到手机、Mac 发通知）：Cue 用 tell 标的急事，与你在等的——回答你那一轮的回复或出错（这一轮还没提示过你时，`replyCueRound`），
  /// Cue 起不来（`CueKeeper`）。
  public var urgent: Bool
  public var taskID: UUID?
  public var answer: String?
  public var answeredAt: Date?
  /// 你开口收起这条提问的那句话（`CueQuestionEnd`）：在 Cue 页说的是你的消息的 id，在挂着它的会话里说的是那句的投送请求的 id；放回"等你"时清掉。
  public var setAsideBy: UUID?
  /// 你的消息或回答被交给 Cue 的大脑的时刻（由 Cue 运行的那台 Mac 写）；回答晚于它时（别的设备同步来的另一个回答）要再交一次。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  public var tools: ChatMessage.Tools?
  /// 回复所对应的真实请求集合（CueKeeper 在调用开始时接走的消息 ID，同步）；空集合是主动消息，nil 是来源还未确认。
  /// 同一请求可有多条回复；有回复不代表执行完成。整轮没有正文时在经过行记录已处理的集合，不编造一句回复。
  public var answeredRequests: [UUID]? = nil
  /// Cue 自己醒来的那一轮为什么醒（只在它的经过那一行上，起这一轮时写下、不再变）：Cue 页那一节的第一行与叫醒的接力都只读它。
  public var wake: CueWake? = nil
  /// 写下那一刻它提到的那几处的样子（关联的任务、叫醒它的那几处，`CuePlace`）：Cue 页按它画，写下就不再变。
  public var places: [String: CuePlace] = [:]
  /// 手机推送的标志（明文、可查询，服务端订阅按它推，见 `CuePush`）：写下时置位，随那一次上传送出后清掉，远端带回来的不留。
  var notify: CuePush?
  /// 服务器收下过这条（读的时候由同步元数据推出，不存，`Speech.reachedServerSQL`）：你的话"已发出"的依据。
  public internal(set) var reachedServer = false

  public var alerts: Bool { author == .known(.cue) && (choices != nil || urgent) }
}

extension CueMessage: Record {
  static let table = Table.cueMessages
  static let columns = [
    "id", "author", "text", "choices", "urgent", "taskID", "answer", "answeredAt", "deliveredAt", "createdAt", "modifiedAt", "notify", "tools",
    "ask", "askAction", "askRule", "askShots", "setAsideBy", "wake", "places", "shownText", "answeredRequests",
  ]
  var bindings: [any SQLBindable] {
    [
      id, author.rawValue, shownText == nil ? text : "", choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt,
      notify?.rawValue, tools?.stored, asked?.stored, askAction, askRule, JSONColumn.encodeList(shots), setAsideBy, wake?.stored,
      places.isEmpty ? nil : JSONColumn.encode(places), shownText?.stored, answeredRequests.map { JSONColumn.encode($0) },
    ]
  }
  init(row: Row) {
    let shown = row.textOrNil(20).flatMap(ShownText.init(stored:))
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: shown?.text ?? row.text(2), shownText: shown,
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), asked: row.textOrNil(13).flatMap(CueAsked.init(stored:)),
      askAction: row.textOrNil(14), askRule: row.textOrNil(15), shots: JSONColumn.decodeList(CueShot.self, from: row.textOrNil(16)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), setAsideBy: row.uuidOrNil(17), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), tools: row.textOrNil(12).flatMap(ChatMessage.Tools.init(stored:)), answeredRequests: JSONColumn.decode([UUID].self, from: row.textOrNil(21)),
      wake: row.textOrNil(18).flatMap(CueWake.init(stored:)),
      places: JSONColumn.decode([String: CuePlace].self, from: row.textOrNil(19)) ?? [:], notify: row.textOrNil(11).flatMap(CuePush.init(rawValue:)), reachedServer: Self.reachedServer(in: row))
  }
}

/// 一条只有一种，订阅各按一种值，所以一条只推一次。
/// 要提示你、你又不在 Mac 上开着 Cue 页的出可见通知（同时叫醒 App 拉一次），其余只静默叫醒 App 拉一次（小组件、实时活动跟着变）。
package enum CuePush: String, Sendable {
  case alert = "cue"
  case wake = "said"
}

/// 一条提问怎么结束（`CueStore.endCueQuestion`）：几种结局落到同一个状态上（`CueMessage.answeredAt`），没有"关掉"。
/// 你的话也可能只是别的想法：Cue 读了判断不是在答它，就放回"等你"（`CueStore.restoreCueQuestion`）；那句没交给 Cue 就撤回了，也放回。
/// 你在挂着它的会话里开口（`CueStore.questionsOn`），它同样当场收起，算你在那边答了：不交给 Cue、不叫醒它；那句撤回或移除了才放回。
public enum CueQuestionEnd: Equatable, Sendable {
  case answered(String)
  case withdrawn
}

/// 你在 Cue 页读到哪（同步，只有一行，各端都写）：读到的那条 Cue 的话写下的时刻，就记成这一行的修改时间，没有别的列。
/// 同步时两个版本按修改时间取晚的（`CueStore.applyVersion`），本机也只往后挪（`CueStore.markCueRead`）：两台设备各读各的，
/// 谁也冲不掉另一台读得更远的；另记一列"读到哪"的话，按修改时间取胜的那一版可能读得更近。新消息的规则在 `CueStore.cueUnread`。
enum CueRead {
  static let recordID = DeterministicID.uuid("cue-read")
  static let columns = ["id", "modifiedAt"]
}

public enum CueReport {
  public static func text(task: String, evidence: [String]) -> ShownText {
    ShownText("「\(task)」做完了\n\n\(evidence.map { "- \($0)" }.joined(separator: "\n"))")
  }
}

public enum CueAlert {
  static let bodyLimit = 300

  public static func content(name: String?, text: String, asking: CueAsking?, choices: [String]?, looks: [String]) -> (title: String, body: String) {
    let body: String
    if let asking, let choices {
      let shots = looks.isEmpty ? [] : [String(localized: "看图：\(looks.joined(separator: String(localized: "；")))")]
      body = ([asking.question] + [asking.why].compactMap(\.self) + shots + [choices.joined(separator: " / ")]).joined(separator: "\n")
    } else {
      let plain = CueFormat.plainText(text)
      body = String(AttributedString(inlineMarkdown: plain).characters).trimmingCharacters(in: .whitespacesAndNewlines).clipped(bodyLimit)
    }
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
