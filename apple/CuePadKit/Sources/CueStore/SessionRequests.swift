import Foundation

public enum AnswerValue: Sendable, Equatable {
  case option(String)
  case confirmed(Bool)
  case text(String)

  public var said: String {
    switch self {
    case .option(let said), .text(let said): said
    case .confirmed: label
    }
  }

  public var shown: ShownText? {
    guard case .confirmed(let yes) = self else { return nil }
    return yes ? ShownText("是") : ShownText("否")
  }

  public var label: String { shown?.text ?? said }
}

public struct Answer: Sendable, Equatable, StoredJSON {
  public var promptID: String
  public var value: AnswerValue
  public var question: String?

  public init(promptID: String, value: AnswerValue, question: String? = nil) {
    self.promptID = promptID
    self.value = value
    self.question = question
  }

  public var stored: String { JSONColumn.encode(self) }

  private enum CodingKeys: String, CodingKey { case promptID, option, confirmed, text, question }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    promptID = try c.decode(String.self, forKey: .promptID)
    question = try c.decodeIfPresent(String.self, forKey: .question)
    if let option = try c.decodeIfPresent(String.self, forKey: .option) {
      value = .option(option)
    } else if let confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) {
      value = .confirmed(confirmed)
    } else if let text = try c.decodeIfPresent(String.self, forKey: .text) {
      value = .text(text)
    } else {
      throw DecodingError.dataCorruptedError(forKey: .option, in: c, debugDescription: "没有答案")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(promptID, forKey: .promptID)
    try c.encodeIfPresent(question, forKey: .question)
    switch value {
    case .option(let option): try c.encode(option, forKey: .option)
    case .confirmed(let confirmed): try c.encode(confirmed, forKey: .confirmed)
    case .text(let text): try c.encode(text, forKey: .text)
    }
  }
}

public struct SessionConfig: Sendable, Equatable, StoredJSON {
  public var model: ModelKey?
  public var thinking: ThinkingLevel?
  public var fast: Bool?
  public var name: String?

  public init(model: ModelKey? = nil, thinking: ThinkingLevel? = nil, fast: Bool? = nil, name: String? = nil) {
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.name = name
  }

  init?(stored: String) {
    guard let value = JSONColumn.decode(Self.self, from: stored), value.model != nil || value.thinking != nil || value.fast != nil || value.name != nil else {
      return nil
    }
    self = value
  }
}

public enum FolderSource: Sendable, Equatable {
  case project(UUID)
  case besideSession(String)
}

public struct LaunchRequest: Sendable, Equatable, StoredJSON {
  public var project: UUID
  public var prompt: String?
  public var token: String
  public var agent: AgentKind
  public internal(set) var name: String?
  public internal(set) var createdForTaskID: UUID?
  public var model: ModelKey?
  public var thinking: ThinkingLevel?
  public var fast: Bool

  public init(
    project: UUID, prompt: String?, token: String, agent: AgentKind = .pi, model: ModelKey? = nil, thinking: ThinkingLevel? = nil, fast: Bool = false
  ) {
    self.project = project
    self.prompt = prompt
    self.token = token
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.agent = agent
  }

  private enum CodingKeys: String, CodingKey { case project, prompt, token, agent, name, model, thinking, fast, createdForTaskID }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    project = try c.decode(UUID.self, forKey: .project)
    prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
    token = try c.decode(String.self, forKey: .token)
    agent = try c.decode(AgentKind.self, forKey: .agent)
    name = try c.decodeIfPresent(String.self, forKey: .name)
    createdForTaskID = try c.decodeIfPresent(UUID.self, forKey: .createdForTaskID)
    model = try c.decodeIfPresent(ModelKey.self, forKey: .model)
    thinking = try c.decodeIfPresent(ThinkingLevel.self, forKey: .thinking)
    fast = try c.decodeIfPresent(Bool.self, forKey: .fast) ?? false
  }
}

public struct BindRequest: Sendable, Equatable, StoredJSON {
  public var project: UUID
  public var folder: FolderSource?

  public init(project: UUID, folder: FolderSource?) {
    self.project = project
    self.folder = folder
  }

  private enum CodingKeys: String, CodingKey { case project, unbind, folderProject, folderSession }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    project = try c.decode(UUID.self, forKey: .project)
    if try c.decodeIfPresent(Bool.self, forKey: .unbind) == true {
      folder = nil
    } else if let id = try c.decodeIfPresent(UUID.self, forKey: .folderProject) {
      folder = .project(id)
    } else if let sessionID = try c.decodeIfPresent(String.self, forKey: .folderSession) {
      folder = .besideSession(sessionID)
    } else {
      throw DecodingError.dataCorruptedError(forKey: .folderProject, in: c, debugDescription: "没有来源")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(project, forKey: .project)
    switch folder {
    case .project(let id): try c.encode(id, forKey: .folderProject)
    case .besideSession(let sessionID): try c.encode(sessionID, forKey: .folderSession)
    case nil: try c.encode(true, forKey: .unbind)
    }
  }
}
