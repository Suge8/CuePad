import Foundation

// 手机发给 Mac 的请求正文（投送请求 `content` 里的 JSON）。

public enum PiAnswerValue: Sendable, Equatable {
  /// 选择框选中的选项原文
  case option(String)
  /// 确认框的是或否
  case confirmed(Bool)
  /// 输入框填的文字
  case text(String)

  /// 写进对话的正文（`PiChatRole.answer`）：选项与填的字照原文；确认框是作答那台的语言，各端照 `shown` 按自己的语言写。
  public var said: String {
    switch self {
    case .option(let said), .text(let said): said
    case .confirmed: label
    }
  }

  /// 确认框的是或否（各端按自己的语言写）；选项与填的字只有原文，为 nil。
  public var shown: ShownText? {
    guard case .confirmed(let yes) = self else { return nil }
    return yes ? ShownText("是") : ShownText("否")
  }

  /// 答了什么，这台设备的语言。
  public var label: String { shown?.text ?? said }
}

/// 手机发给 Mac 的作答：哪次弹窗、答什么。存在投送请求（方式 `answer`）的正文里（JSON，答案按种类各占一个键）。
public struct PiAnswer: Sendable, Equatable, StoredJSON {
  public var promptID: String
  public var value: PiAnswerValue
  /// 你答的那个问题的原文（`PiQuestion.text`）：作答成功后随答案写进对话（`PiChatRole.answer`）；更旧的版本写的请求没有
  public var question: String?

  public init(promptID: String, value: PiAnswerValue, question: String? = nil) {
    self.promptID = promptID
    self.value = value
    self.question = question
  }

  /// 作答请求的正文（App 的回复框作答经发消息的那条路写出）。
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

/// 手机发给 Mac 的会话配置：换模型、改思考强度，至少改一项。存在投送请求（方式 `config`）的正文里（JSON）。
/// 先换模型再设思考强度：强度按新模型支持的范围取。
public struct PiConfig: Sendable, Equatable, StoredJSON {
  public var model: PiModelKey?
  public var thinking: PiThinkingLevel?
  public var fast: Bool?
  /// 会话名（Pi 的 `/name`）：会话设置，与模型、思考强度同一条路。
  public var name: String?

  public init(model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, fast: Bool? = nil, name: String? = nil) {
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.name = name
  }

  /// 什么都不改、或强度是更新版本的新值（解码不了）时为 nil。
  init?(stored: String) {
    guard let value = JSONColumn.decode(Self.self, from: stored), value.model != nil || value.thinking != nil || value.fast != nil || value.name != nil else {
      return nil
    }
    self = value
  }
}

/// Mac 上的一个文件夹，由那台 Mac 解析：某个项目绑定的目录，或某个会话的工作目录。手机看不到完整路径，请求里只指名"从哪里取"。
public enum PiFolder: Sendable, Equatable {
  case project(UUID)
  case besideSession(String)
}

/// 在 Mac 上开一个新 Pi 会话（投送方式 `start` 的正文，存为 JSON）：开在项目绑定的文件夹里——新会话的目录只由项目绑定推出；
/// Mac 在后台托管它（Pi 的 RPC 模式，没有终端界面），开场的话作为第一条消息送入。
/// `token` 由发起方生成，带到新会话的同步记录上（`PiSessionState.launchToken`），发起方据此认领。
public struct PiLaunch: Sendable, Equatable, StoredJSON {
  public var project: UUID
  /// 开场的话（可空）。
  public var prompt: String?
  public var token: String
  /// 用哪个 Agent 开；旧版本写的没有，是 Pi（`opening`）
  public var agent: AgentKind?
  /// 实际用哪家开（Mac 执行、界面写"正在开 X 会话"都读它）。
  public var opening: AgentKind { agent ?? .pi }
  /// 会话名：从任务开的会话叫那个叶子的标题，由 `CueStore.requestLaunch` 按带着的卡定（`CueStore.sessionName(forCard:)`），调用方不传；
  /// nil 是 Agent 的默认名（第一句话）。模型与思考强度可选（nil 用 Agent 的默认）。三者作为启动参数一起生效。
  /// 强度是更新版本的新值时整条读不出，按不认识的请求失败。
  public internal(set) var name: String?
  public var model: PiModelKey?
  public var thinking: PiThinkingLevel?
  public var fast: Bool

  public init(
    project: UUID, prompt: String?, token: String, agent: AgentKind = .pi, model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, fast: Bool = false
  ) {
    self.project = project
    self.prompt = prompt
    self.token = token
    self.model = model
    self.thinking = thinking
    self.fast = fast
    self.agent = agent
  }

  private enum CodingKeys: String, CodingKey { case project, prompt, token, agent, name, model, thinking, fast }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    project = try c.decode(UUID.self, forKey: .project)
    prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
    token = try c.decode(String.self, forKey: .token)
    agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent)
    name = try c.decodeIfPresent(String.self, forKey: .name)
    model = try c.decodeIfPresent(PiModelKey.self, forKey: .model)
    thinking = try c.decodeIfPresent(PiThinkingLevel.self, forKey: .thinking)
    fast = try c.decodeIfPresent(Bool.self, forKey: .fast) ?? false
  }
}

/// 请 Mac 给项目绑定文件夹（投送方式 `bind` 的正文，存为 JSON）：`folder` 是从哪里取（某个会话的工作目录，或另一个项目已绑的目录），
/// nil 是解除绑定。绑定按项目 id 记，项目记录晚到这台 Mac 也对得上。
public struct PiBind: Sendable, Equatable, StoredJSON {
  public var project: UUID
  public var folder: PiFolder?

  public init(project: UUID, folder: PiFolder?) {
    self.project = project
    self.folder = folder
  }

  private enum CodingKeys: String, CodingKey { case project, unbind, folderProject, folderSession }

  /// 来源不认识（更新版本写的）、也不是解除绑定的读不出——不能把它当成解除。
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
