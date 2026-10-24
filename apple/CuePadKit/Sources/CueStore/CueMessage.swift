import CueText
import Foundation

// Cue：常驻的总控 Agent。它不写代码，只经 CuePad 的任务派活、跟进、问你、记东西。这里是它的数据：
// 对话（`cueMessages`）、记忆（`cueLines` 与本机的摘要缓存 `cueSummaries`）、设置（`cueProfile`）、此刻在做什么（`cueState`）。
// 值班时它管没做完的事与不归没做完的事的活会话（`CueStore.cueBoard`），不另记"由谁跟进"。

/// 不认识的（旧版本写下的交接备忘 `handoff`、更新版本的新种类）界面不列、不交给大脑。
public enum CueAuthor: String, Sendable, CaseIterable {
  case you
  /// Cue 对你说的；带选项的是"等你"
  case cue
  /// Cue 自己醒来那一轮的动态（不推送，Cue 页每轮一行旁注）：没有正文的是那一轮的经过，带着它为什么醒（`wake`）与做了什么（`tools`）
  case note
  /// 你发起的一轮的经过（`tools`，没有正文）：排在这一轮开始的位置，这一轮说的话与结果都在它之后（`CueStore.recordCueRound`）。
  /// Cue 自己醒来的一轮的经过是一条没有正文的动态（`note`），跟着动态收起
  case round
}

/// Cue 页的对话：Cue 对话唯一的事实源（不读运行时的会话文件）。写入后只有提问的结束（`answer`、`answeredAt`）与送达（`deliveredAt`）会变；
/// 一轮的经过那一行（`round`，或没有正文的 `note`）随这一轮做到哪改它的清单。
/// 带选项的是提问，只有一个状态：`answeredAt` 为空是开着，有值是结束了（`CueQuestionEnd`）；结束了不再变，只有你开口收起的 Cue 放得回。
public struct CueMessage: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var author: Open<CueAuthor>
  /// 正文（`CueFormat`）；你的消息可带图片引用。
  public var text: String
  /// 给你的选项；有选项的 Cue 消息在等你（规则见 `CueStore.cueMessagesWaitingForYou`）。选项只由 `CueAsk.choices` 在写入时按 `asked` 写出、
  /// Cue 不能自拟；写下就不再变，卡片与通知照它显示。
  public var choices: [String]?
  /// 提问的类别与范围（明文、同步，写入时定下）：哪一类事，与关联任务当时所在的项目（没关联任务为 nil，是所有项目）。
  /// 选项里"以后……不用问"照它写，选了就把它原样记进允许清单（`CueStore.endCueQuestion`），所以字面范围与实际放行的一致。
  public var asked: CueAllow?
  /// 提问要做的动作与依据的规矩（`CueAsking`；用户内容，加密同步）。
  public var askAction: String?
  public var askRule: String?
  /// Cue 点名要你看的图，按它给的先后（`CueShot.checked`）：提问的是回答它必须看的，做完的结果是证明结论的最终成果（`CueStore.finishTask`）。
  /// 卡片、通知与全屏预览只读它，没点名的没有图。看什么是用户内容，加密同步；列与同步字段沿用最初只有提问时的名字 askShots（同步表不改已有列）。
  public var shots: [CueShot] = []
  public var ask: CueAsk? { asked?.ask.known }
  /// 提问问的是什么（`CueAsking.init(stored:)`）；不是提问，或是认不出类别、没有动作短语的提问为 nil。
  public var asking: CueAsking? { CueAsking(stored: ask, action: askAction, rule: askRule) }
  /// 要提示你（推到手机、Mac 发通知）：Cue 用 tell 标的急事，与你在等的——回答你那一轮的回复或出错（这一轮还没提示过你时，`replyCueRound`），
  /// Cue 起不来（`CueKeeper`）。
  public var urgent: Bool
  public var taskID: UUID?
  /// 你选的那一项（`choices` 之一；更旧版本存下的可能是卡上另外写的一句，照原文显示）；收起、撤回的为 nil。
  public var answer: String?
  public var answeredAt: Date?
  /// 你开口收起这条提问的那句话（你的消息的 id，`CueQuestionEnd`）；放回"等你"时清掉。
  public var setAsideBy: UUID?
  /// 你的消息或回答被交给 Cue 的大脑的时刻（由 Cue 运行的那台 Mac 写）；回答晚于它时（别的设备同步来的另一个回答）要再交一次。
  public var deliveredAt: Date?
  public var createdAt: Date
  public var modifiedAt: Date
  /// 一轮的经过那一行的清单（Cue 那一轮调过的工具，`CueActivity`），与回答注脚同一个样子；别的行没有。
  public var tools: PiChatMessage.Tools?
  /// Cue 自己醒来的那一轮为什么醒（只在它的经过那一行上，起这一轮时写下、不再变）：Cue 页那一节的第一行与叫醒的接力都只读它。
  public var wake: CueWake? = nil
  /// 手机推送的标志（明文、可查询，服务端订阅按它出通知）：写下时按 `alerts` 与他在不在 Mac 上开着 Cue 页置位（`CueStore.insertCueMessage`），
  /// 随那一次上传送出后清掉，远端带回来的不留（同 `PiSessionState.notify`，见 docs/sync.md「Agent 与 Cue 的通知」）。
  var notify: Bool = false
  /// 服务器收下过这条（读的时候由同步元数据推出，不存，`Speech.reachedServerSQL`）：你的话"已发出"的依据。
  public internal(set) var reachedServer = false

  /// 要提示你的 Cue 消息（手机推送与 Mac 通知同一条规则）：Cue 对你说的，带选项来问（"等你"）或 `urgent`。
  public var alerts: Bool { author == .known(.cue) && (choices != nil || urgent) }
}

extension CueMessage: Record {
  static let table = Table.cueMessages
  static let columns = [
    "id", "author", "text", "choices", "urgent", "taskID", "answer", "answeredAt", "deliveredAt", "createdAt", "modifiedAt", "notify", "tools",
    "ask", "askAction", "askRule", "askShots", "setAsideBy", "wake",
  ]
  /// `notify` 的值（订阅的谓词按它）。
  package static let notifyFlag = "cue"
  var bindings: [any SQLBindable] {
    [
      id, author.rawValue, text, choices.map { JSONColumn.encode($0) }, urgent, taskID, answer, answeredAt, deliveredAt, createdAt, modifiedAt,
      notify ? Self.notifyFlag : nil, tools?.stored, asked?.stored, askAction, askRule, JSONColumn.encodeList(shots), setAsideBy, wake?.stored,
    ]
  }
  init(row: Row) {
    self.init(
      id: row.uuid(0), author: Open(rawValue: row.text(1)), text: row.text(2),
      choices: JSONColumn.decode([String].self, from: row.textOrNil(3)), asked: row.textOrNil(13).flatMap(CueAllow.init(stored:)),
      askAction: row.textOrNil(14), askRule: row.textOrNil(15), shots: JSONColumn.decodeList(CueShot.self, from: row.textOrNil(16)), urgent: row.bool(4), taskID: row.uuidOrNil(5),
      answer: row.textOrNil(6), answeredAt: row.dateOrNil(7), setAsideBy: row.uuidOrNil(17), deliveredAt: row.dateOrNil(8), createdAt: row.date(9),
      modifiedAt: row.date(10), tools: row.textOrNil(12).flatMap(PiChatMessage.Tools.init(stored:)), wake: row.textOrNil(18).flatMap(CueWake.init(stored:)),
      notify: row.textOrNil(11) != nil, reachedServer: row.bool(19))
  }
}

/// 一条提问怎么结束（`CueStore.endCueQuestion`）：几种结局落到同一个状态上（`CueMessage.answeredAt`），没有"关掉"。
/// 卡上只能选；你不选、在 Cue 页底下开口，还开着的卡当场收起，算你直接说了（`CueStore.addCueMessage`，记下是哪句话收起的，`CueMessage.setAsideBy`）。
/// 你的话也可能只是别的想法：Cue 读了判断不是在答它，就放回"等你"（`CueStore.restoreCueQuestion`）；那句没交给 Cue 就撤回了，也放回。
public enum CueQuestionEnd: Equatable, Sendable {
  /// 你选了一项（`choices` 之一）：交给 Cue、叫醒它
  case answered(String)
  /// Cue 撤回了（拿了主意或情况变了）：它自己撤的，不交给它
  case withdrawn
}

/// 你在 Cue 页读到哪（同步，只有一行，各端都写）：读到的那条 Cue 的话写下的时刻，就记成这一行的修改时间，没有别的列。
/// 同步时两个版本按修改时间取晚的（`CueStore.applyVersion`），本机也只往后挪（`CueStore.markCueRead`）：两台设备各读各的，
/// 谁也冲不掉另一台读得更远的；另记一列"读到哪"的话，按修改时间取胜的那一版可能读得更近。新消息的规则在 `CueStore.cueUnread`。
enum CueRead {
  static let recordID = DeterministicID.uuid("cue-read")
  static let columns = ["id", "modifiedAt"]
}

/// Cue 做完一件顶层任务后告诉你的结果（`CueStore.finishTask`）：一行"「任务名」做完了"，下面每条证据一个要点。
public enum CueReport {
  public static func text(task: String, evidence: [String]) -> String {
    (["「\(task)」做完了", ""] + evidence.map { "- \($0)" }).joined(separator: "\n")
  }
}

/// Cue 通知的文案（Mac 本机通知与手机锁屏通知同一条规则）：标题是 Cue 的名字（空的用 `CueProfile.defaultName`）；
/// "等你"的正文是要你定什么、规矩那一类引的规矩（`CueAsking`）、要看的图各看什么（`looks`），接选项，与卡片同源；其余（读不出 `CueAsking` 的提问也是）是 Cue 的原话
/// （去掉图片，行内的 Markdown 记号只留字，至多 `bodyLimit` 字）。
public enum CueAlert {
  static let bodyLimit = 300

  public static func content(name: String?, text: String, asking: CueAsking?, choices: [String]?, looks: [String]) -> (title: String, body: String) {
    let body: String
    if let asking, let choices {
      let shots = looks.isEmpty ? [] : ["看图：" + looks.joined(separator: "；")]
      body = ([asking.question] + [asking.why].compactMap(\.self) + shots + [choices.joined(separator: " / ")]).joined(separator: "\n")
    } else {
      let plain = CueFormat.plainText(text)
      let words = (try? AttributedString(markdown: plain, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) }
      body = (words ?? plain).trimmingCharacters(in: .whitespacesAndNewlines).clipped(bodyLimit)
    }
    let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? CueProfile.defaultName : name, body)
  }
}
