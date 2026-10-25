import CueText
import Foundation

/// Cue 要先问你的几类事（唯一定义，Cue 的提示词与工具说明照它写）：收不回或越出它职责的事。只有这几类能写带选项的"等你"
/// （`CueStore.addCueMessage` 的 `ask`）；调研方案、设计取舍、实现路线、子任务与整件事算不算做完，Cue 按你的规矩与最佳实践自己定，做完告诉你。
/// 选项也由这里给（`choices`），Cue 不能自拟"照这个做 / 我再看看"这类确认；别的想法（不同意、选别的方案、补一句条件）他在 Cue 页底下直接说，
/// 卡随之收起（`CueQuestionEnd`）。
/// 给人看的只有 `name`（选项）与 `why`；`definition` 只给 Cue 看。
public enum CueAsk: String, CaseIterable, Sendable {
  case push, merge, release, delete, outside, budget, rule

  /// 这类事给人看的叫法（"以后推送代码都不用问"）；规矩那一类不出现在选项里。
  /// 范围要与 `definition` 一样大：选项照它写，选了放行的是整类。
  public var name: String {
    switch self {
    case .push: "推送代码"
    case .merge: "合并进共享分支"
    case .release: "发布或部署"
    case .delete: "删除文件、分支或数据"
    case .outside: "动项目外的东西"
    case .budget: "超出预算"
    case .rule: "你的规矩要先问的事"
    }
  }

  /// 这类事的确切范围，只给 Cue 看（系统提示与工具说明）。
  public var definition: String {
    switch self {
    case .push: "推送到远端"
    case .merge: "合并到共享分支"
    case .release: "发布或部署"
    case .delete: "删除文件、分支或数据"
    case .outside: "动项目以外的东西"
    case .budget: "超出预算"
    case .rule: "他的规矩明确要先问的事，或要违反、改动他的规矩"
    }
  }

  /// 第一项（主按钮）：允许这一次。
  public static let once = "可以"

  /// 提问的第二项：这类事以后在 `project`（关联任务所在项目的名字）里不用问，nil 是所有项目里都不用问。
  /// 选了它 `CueStore.endCueQuestion` 把这句原话记成一条他说的、一直记着的记忆，范围就在字面上。规矩那一类没有这一项：一律放行等于没有规矩。
  public func always(in project: String?) -> String? {
    guard self != .rule else { return nil }
    return project.map { "以后「\($0)」里\(name)不用问" } ?? "以后\(name)都不用问"
  }

  /// 所有项目里都不用问那一项。
  public var always: String? { always(in: nil) }

  /// 提问的选项（写入时定下、照存，之前写下的照旧显示当时的字）：可以，与"以后……不用问"（范围同上）。
  public func choices(in project: String?) -> [String] { [Self.once] + (always(in: project).map { [$0] } ?? []) }
}

/// Cue 的一次提问问的是什么（`CueStore.addCueMessage`）：哪一类、要做的动作，规矩那一类还有是哪条规矩；要你看的图在消息上（`CueMessage.shots`）。
/// 动作、规矩与每张图看什么是 Cue 写的短语，卡片、侧栏与菜单栏的摘要、小组件、本机与手机通知都只露这些，不露 Cue 的原话。
public struct CueAsking: Equatable, Sendable {
  public let ask: CueAsk
  /// 要做的动作（"推送 scheduler 的重连修复"）。
  public let action: String
  /// 规矩那一类依据的规矩（"改数据库结构前先问我"）；别的类没有。
  public let rule: String?

  /// 动作与规矩各至多这么多字。
  public static let phraseLimit = 30

  /// Cue 提问时给的：动作必填，规矩那一类还要写规矩；都是一行、不超过 `phraseLimit` 字，不合要求抛 `phrase`。
  public init(_ ask: CueAsk, action: String?, rule: String? = nil) throws {
    self.ask = ask
    self.action = try Self.phrase(action, "带 ask 要写 doing", "要做的动作，如“推送 scheduler 的重连修复”", limit: Self.phraseLimit)
    self.rule = ask == .rule ? try Self.phrase(rule, "带 ask 要写 rule", "依据的规矩，照他的原话，如“改数据库结构前先问我”", limit: Self.phraseLimit) : nil
  }

  /// 照存下的读回（`CueMessage.asking`、通知服务扩展读的同步记录）：认不出类别（更新的版本写的）、没有动作短语（旧版本写的，
  /// 或规矩那一类没写规矩）的不算，卡片、摘要与通知照普通的话写它的第一行，回答的引用也是这一行。
  package init?(stored ask: CueAsk?, action: String?, rule: String?) {
    guard let ask, let action, ask != .rule || rule != nil else { return nil }
    self.ask = ask
    self.action = action
    self.rule = rule
  }

  /// Cue 写的短语：去掉首尾空白与句末标点，一行、不空、不超过 `limit` 字，不合要求抛 `phrase`（`field` 是报错的开头）。
  fileprivate static func phrase(_ text: String?, _ field: String, _ hint: String, limit: Int) throws -> String {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "。？?！!"))
    guard !trimmed.isEmpty, trimmed.count <= limit, !trimmed.contains(where: \.isNewline) else {
      throw CueStoreError.phrase(field: field, hint: hint, limit: limit)
    }
    return trimmed
  }

  /// 要你定什么（卡片第一句、摘要、通知同一句）。
  public var question: String {
    // 动作两头是字母或数字时与汉字之间空一格（"可以合并进 main 吗？"），同界面上中英文混排的写法
    func gap(_ character: Character?) -> String { character.map { $0.isASCII && ($0.isLetter || $0.isNumber) } == true ? " " : "" }
    return "可以\(gap(action.first))\(action)\(gap(action.last))吗？"
  }

  /// 规矩那一类为什么问你：引他的规矩原话（卡片与通知的第二句）。别的类没有：推送、删除这些收不回的地方他自己知道，卡上只留问句。
  public var why: String? { rule.map { "你说过「\($0)」。" } }
}

/// Cue 点名要你看的一张图（`CueMessage.shots`）：发到手机的哪一份（`PiPreview.id`）与看它的什么（Cue 写的一句）。写下就不再变；那一份不在了（会话的预览过期删掉）就不显示。
public struct CueShot: Codable, Hashable, Sendable {
  public let preview: UUID
  public let look: String

  /// 一条消息至多这么多张：只挑回答问题必须看的、证明结论的。
  public static let limit = 4
  /// 看什么至多这么多字。
  public static let lookLimit = 20

  public init(preview: UUID, look: String) {
    self.preview = preview
    self.look = look
  }

  /// Cue 点名的一组：至多 `limit` 张、不重复，每张一句看什么（一行、`lookLimit` 字以内）；多了或重复抛 `shots`，看什么不合要求抛 `phrase`。
  public static func checked(_ shots: [CueShot]) throws -> [CueShot] {
    guard shots.count <= limit, Set(shots.map(\.preview)).count == shots.count else { throw CueStoreError.shots(limit: limit) }
    return try shots.map {
      CueShot(preview: $0.preview, look: try CueAsking.phrase($0.look, "show 每张要写 look", "这张看什么，如“方案 1：大按钮占满一行”", limit: lookLimit))
    }
  }
}

/// 一条提问问的哪一类、在哪（`CueMessage.asked`）：类别，与关联任务当时所在的项目（`project`，没关联任务为 nil）。选项第二项的范围照它写，
/// 等你列的依据那一行写这个项目。存成"类别"或"类别/项目 id"；更新的版本写的类别原样留着（`Open`）。
public struct CueAsked: Hashable, Sendable {
  public var ask: Open<CueAsk>
  public var project: UUID?

  public init(_ ask: CueAsk, project: UUID?) {
    self.ask = .known(ask)
    self.project = project
  }

  package init?(stored: String) {
    let parts = stored.split(separator: "/", maxSplits: 1).map(String.init)
    guard let raw = parts.first else { return nil }
    ask = Open(rawValue: raw)
    project = parts.count > 1 ? UUID(uuidString: parts[1]) : nil
  }

  var stored: String { ask.rawValue + (project.map { "/" + $0.uuidString.lowercased() } ?? "") }
}
