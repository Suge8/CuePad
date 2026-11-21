import CueText
import Foundation

public enum CueAsk: String, CaseIterable, Sendable {
  case push, merge, release, delete, outside, budget, taste, rule, habit

  public static let byCue = allCases.filter { $0 != .habit }

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
    case .habit: String(localized: "把常说的做法记成重点")
    }
  }

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
    case .habit: "把他在各会话里反复交代的一条做法记成重点"
    }
  }

  public static let once = String(localized: "可以")

  public var quotesYou: Bool { self == .rule || self == .habit }

  public var allowable: Bool { !quotesYou && self != .taste }

  public var declinable: Bool { self == .habit }

  public func always(in project: String?) -> String? {
    guard allowable else { return nil }
    return project.map { CueMemoryLine.fitting($0) { String(localized: "以后「\($0)」里\(name)不用问") } } ?? String(localized: "以后\(name)都不用问")
  }

  public var always: String? { always(in: nil) }

  public func choices(in project: String?) -> [String] { [Self.once] + (always(in: project).map { [$0] } ?? []) }
}

public struct CueAsking: Equatable, Sendable {
  public let ask: CueAsk
  public let action: String
  public let rule: String?

  public static let phraseLimit = 30

  public init(_ ask: CueAsk, action: String?, rule: String? = nil) throws {
    self.ask = ask
    self.action = try Self.phrase(action, "带 ask 要写 doing", "要做的动作，如“推送 scheduler 的重连修复”", limit: Self.phraseLimit)
    self.rule = ask.quotesYou ? try Self.phrase(rule, "带 ask 要写 rule", "依据的规矩，照他的原话，如“改数据库结构前先问我”", limit: Self.phraseLimit) : nil
  }

  public init(habit practice: String?) throws {
    ask = .habit
    action = String(localized: "记住")
    rule = try Self.phrase(practice, "要写 rule", "那条做法，照他的话，如“不加没人要的测试”", limit: Self.phraseLimit)
  }

  package init?(stored ask: CueAsk?, action: String?, rule: String?) {
    guard let ask, let action, !ask.quotesYou || rule != nil else { return nil }
    self.ask = ask
    self.action = action
    self.rule = rule
  }

  fileprivate static func phrase(_ text: String?, _ field: String, _ hint: String, limit: Int) throws -> String {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "。？?！!"))
    guard !trimmed.isEmpty, trimmed.count <= limit, !trimmed.contains(where: \.isNewline) else {
      throw CueStoreError.phrase(field: field, hint: hint, limit: limit)
    }
    return trimmed
  }

  public var question: String {
    if ask == .habit, let rule { return String(localized: "\(action)「\(rule)」？") }
    let text = String(localized: "可以\(action)吗？")
    guard let range = text.range(of: action) else { return text }
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

  public var why: String? {
    guard let rule, ask != .habit else { return nil }
    return String(localized: "你说过「\(rule)」。")
  }
}

public struct CueShot: Codable, Hashable, Sendable {
  public let preview: UUID
  public let look: String

  public static let limit = 4
  public static let lookLimit = 20

  public init(preview: UUID, look: String) {
    self.preview = preview
    self.look = look
  }

  public static func checked(_ shots: [CueShot]) throws -> [CueShot] {
    guard shots.count <= limit, Set(shots.map(\.preview)).count == shots.count else { throw CueStoreError.shots(limit: limit) }
    return try shots.map {
      CueShot(preview: $0.preview, look: try CueAsking.phrase($0.look, "show 每张要写 look", "这张看什么，如“方案 1：大按钮占满一行”", limit: lookLimit))
    }
  }
}

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
