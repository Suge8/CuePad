import CueText
import Foundation

/// Cue 要先问你的几类事（唯一定义，Cue 的提示词与工具说明照它写）：收不回或越出它职责的事，与只能按你口味定的审美取舍。只有这几类能写带选项的"等你"
/// （`CueStore.addCueMessage` 的 `ask`）；调研方案、技术取舍、实现路线、子任务与整件事算不算做完，Cue 按你的规矩与最佳实践自己定，做完告诉你。
/// 选项也由这里给（`choices`），Cue 不能自拟"照这个做 / 我再看看"这类确认；别的想法（不同意、选别的方案、补一句条件）他在 Cue 页底下直接说，
/// 卡随之收起；在挂着它的会话里说也一样（`CueQuestionEnd`）。
/// 给人看的句子都由这里拼（`name` 与 `CueAsking` 的 `question`、`why`），各处不按类别另写；`definition` 只给 Cue 看。
public enum CueAsk: String, CaseIterable, Sendable {
  case push, merge, release, delete, outside, budget, taste, rule

  /// 这类事给人看的叫法（"以后推送代码都不用问"）；不能放行的（`allowable`）不出现在选项里。
  /// 范围要与 `definition` 一样大：选项照它写，选了放行的是整类。
  public var name: String {
    switch self {
    case .push: String(localized: "推送代码")
    case .merge: String(localized: "合并进共享分支")
    case .release: String(localized: "发布或部署")
    case .delete: String(localized: "删除文件、分支或数据")
    case .outside: String(localized: "动项目外的东西")
    case .budget: String(localized: "超出预算")
    case .taste: String(localized: "审美取舍")
    case .rule: String(localized: "你的规矩要先问的事")
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
    case .taste: "只能按他口味定的审美取舍（界面长相、配色、文案语气）"
    case .rule: "他的规矩明确要先问的事，或要违反、改动他的规矩"
    }
  }

  /// 第一项（主按钮）：允许这一次。
  public static let once = String(localized: "可以")

  /// 能不能放行（提问有第二项"以后……不用问"）。规矩那一类不能：一律放行等于没有规矩。审美那一类也不能：问的是选哪个方案而不是准不准做，
  /// "以后不用问"等于把他的口味交给 Cue 的口味，还会让卡上一次误点悄悄拿走以后每次长相的决定；他真要 Cue 定，会说出来、记成规矩。
  public var allowable: Bool { self != .rule && self != .taste }

  /// 提问的第二项：这类事以后在 `project`（关联任务所在项目的名字）里不用问，nil 是所有项目里都不用问。
  /// 选了它 `CueStore.endCueQuestion` 把这句原话记成一条他说的、一直记着的记忆，范围就在字面上；项目名长到一条记忆放不下的截短（`CueMemoryLine.fitting`）。
  /// 不能放行的（`allowable`）没有这一项。
  public func always(in project: String?) -> String? {
    guard allowable else { return nil }
    return project.map { CueMemoryLine.fitting($0) { String(localized: "以后「\($0)」里\(name)不用问") } } ?? String(localized: "以后\(name)都不用问")
  }

  /// 所有项目里都不用问那一项；不能放行的没有。
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
    let text = String(localized: "可以\(action)吗？")
    guard let range = text.range(of: action) else { return text }
    // 动作两头的字母或数字与句子里的汉字之间空一格（"可以合并进 main 吗？"），同界面上中英文混排的写法；英文句子本有空格，不加
    func gap(_ a: Character?, _ b: Character?) -> String {
      guard let a, let b else { return "" }
      func latin(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
      func han(_ c: Character) -> Bool { !c.isASCII && c.isLetter }
      return latin(a) && han(b) || han(a) && latin(b) ? " " : ""
    }
    let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
    let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
    return String(text[..<range.lowerBound]) + gap(before, action.first) + action + gap(action.last, after) + String(text[range.upperBound...])
  }

  /// 问句下面那一句（拍板卡、全屏预览底栏、对话里答完的那句、通知、实时活动都只读它）：只有规矩那一类引他自己的原话——
  /// 这一问为什么来问他只有这句说得出。别的类不写：问句已经说了是什么事，"按你的口味定""请你允许推送代码"这类泛泛的依据只是复述。
  public var why: String? { rule.map { String(localized: "你说过「\($0)」。") } }
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
/// 看板按它把提问归到项目（`TaskBoard`）。存成"类别"或"类别/项目 id"；更新的版本写的类别原样留着（`Open`）。
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
