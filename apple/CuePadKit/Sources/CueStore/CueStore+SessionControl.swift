import CueText
import Foundation

extension CueStore {
  /// 对会话说一句（界面的回复框与 Cue 的 say 共用这一条）：
  /// 1. 会话在等 CuePad 能代答的提问（`PiSessionState.answerableQuestion`）时，这句就是答案（`answerValue`）；答不上抛 `invalidAnswer`，什么都不写。
  /// 2. 否则发出（规则见 `say`）。
  /// 带 `config`（模型、思考强度）时先请会话换上（与界面换模型同一种请求），两条按先后执行；换不了模型抛 `cannotChangeModel`，什么都不写。
  /// 会话已结束也照说：执行它的 Mac 先恢复它。说话不改任务的状态：已完成的事收到话仍是完成。`card` 是这句带着的卡，
  /// `name` 是会话记录还没到时对它的称呼，`host` 是记录还没到时由哪台 Mac 执行。
  public func speak(
    _ content: String, to sessionID: String, name: String = "", card: UUID? = nil, config: PiConfig? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write {
      let session = try sessionTarget(sessionID, name: name)
      var answer: PiAnswer?
      if let question = session.state?.answerableQuestion, let promptID = question.promptID, let kind = question.kind.known {
        let value = CueFormat.plainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
        answer = PiAnswer(promptID: promptID, value: try Self.answerValue(value, kind: kind, options: question.options, allowsOther: question.allowsOther, leading: cue))
      }
      try requestConfig(config, in: session, host: host, cue: cue)
      if let answer {
        return try insertDelivery(answer.stored, to: session.target, on: session.host(or: host), mode: .answer, card: card, cue: cue)
      }
      return try say(content, to: session, card: card, host: host, cue: cue)
    }
  }

  /// 叶子绑着的会话；没有抛 `noSession`（正在开会话抛 `launching`，话正送进上一步的会话抛 `sending`）。
  public func leafSession(_ leaf: UUID) throws -> String {
    let card = try requireLeaf(leaf)
    guard let sessionID = card.piSessionID else {
      if try !launchingLeaves([leaf]).isEmpty { throw CueStoreError.launching(card.heading) }
      if try !sendingLeaves([leaf]).isEmpty { throw CueStoreError.sending(card.heading) }
      throw CueStoreError.noSession(card.heading)
    }
    return sessionID
  }

  /// 说话之前先请会话换上 `config`；换不了模型（`AgentCapabilities.model`，记录没到也算不知道、不换）抛 `cannotChangeModel`。
  /// 必须在写事务内、写别的之前调用：抛错时什么都没写。
  private func requestConfig(_ config: PiConfig?, in session: SessionTarget, host: String, cue: Bool) throws {
    guard let config else { return }
    guard session.state?.capabilities.contains(.model) == true else { throw CueStoreError.cannotChangeModel(session.target.name) }
    _ = try insertDelivery(config.stored, to: session.target, on: session.host(or: host), mode: .config, cue: cue)
  }

  /// 交给会话一句话（`DeliveryMode.send`）：会话在跑这一轮时 Mac 执行时先打断它，以这句开新一轮；忙不忙、打不打断得了由 Mac 执行时定。
  /// Cue 这会儿说不了就抛 `cannotSpeakNow`、什么都不写，它歇下时 Cue 被叫醒再说：停不下这一轮（`speakBlocked`），
  /// 或会打断他发起的那一轮（`inUserTurn`）。正文原样写：收不了图片的会话由 Mac 交出时把图片写成路径。必须在写事务内调用。
  func say(_ content: String, to session: SessionTarget, card: UUID?, host: String, cue: Bool) throws -> DeliveryRequest {
    if cue, let state = session.state, state.speakBlocked != nil {
      guard state.capabilities.contains(.speak) else { throw CueStoreError.terminalOnly(session.target.name) }
      throw CueStoreError.cannotSpeakNow(session.target.name, "在跑，CuePad 打断不了它（在终端里开的）")
    }
    if cue, try inUserTurn(session.target.ref) { throw CueStoreError.cannotSpeakNow(session.target.name, "正在跑他发起的一轮，现在说会打断它") }
    return try insertDelivery(content, to: session.target, on: session.host(or: host), mode: .send, card: card, cue: cue)
  }

  /// 会话正在跑的这一轮是他发起的（`turnOpener`）。
  private func inUserTurn(_ sessionID: String?) throws -> Bool {
    guard let sessionID, try sessionState(sessionID)?.state.known?.isTurnRunning == true else { return false }
    return try turnOpener(sessionID) == .user
  }

  /// 会话最近（或正在跑）的这一轮是谁开的，唯一的一处（"他说的"标记、他那一轮里 Cue 不插嘴、停下归谁接手都只认它）：
  /// 取会话里最近一句你一方的话，按来源分（`PiChatMessage.saidByCue`）。扩展投进来的机器消息（FireCode 交回子代理结果、审查结论）
  /// 开的轮不另算：它是那句话派出去的活交回来了，同等子代理只歇下一次一样，从那句起到真正歇下是一件事。会话里还没有你一方的话为 nil。
  func turnOpener(_ sessionID: String) throws -> TurnOpener? {
    guard let last = try select(
      PiChatMessage.self, where: "sessionID = ? AND role = '\(PiChatRole.user.rawValue)'", [sessionID], orderBy: "seq DESC, id DESC", limit: 1
    ).first else { return nil }
    return last.saidByCue(try cueSentDeliveries(among: [last.deliveryID].compactMap(\.self))) ? .cue : .user
  }

  enum TurnOpener { case user, cue }

  /// 一句话作为提问的答案：选择题给选项原文或从 1 起的序号，收自己写的回答的（`PiQuestion.allowsOther`）其余文字照写；
  /// 不收的，Cue 说的（`leading`）开头正好是一个选项、后面紧跟标点或空白（"B. Redis，多实例共享"、照抄提问的"A. 新建表…"）就按那个选项答，
  /// 后面的说明不送，工具结果会告诉它；你在回复框里写的不这样截，免得说明悄悄丢掉。只认开头：说明里才提到选项（"不换，仍按 A"）猜不准。
  /// 确认题给是或否；文字题照写。答不上抛 `invalidAnswer`。
  private static func answerValue(_ value: String, kind: PiQuestionKind, options: [String], allowsOther: Bool, leading: Bool) throws -> PiAnswerValue {
    switch kind {
    case .text: return .text(value)
    case .select:
      if let hit = options.first(where: { $0 == value }) ?? options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
        return .option(hit)
      }
      if let number = Int(value), options.indices.contains(number - 1) { return .option(options[number - 1]) }
      if allowsOther, !value.isEmpty { return .text(value) }
      let opening = options.filter { option in
        guard leading, !option.isEmpty, value.count > option.count, value.lowercased().hasPrefix(option.lowercased()) else { return false }
        let next = value[value.index(value.startIndex, offsetBy: option.count)]
        return next.isWhitespace || next.isPunctuation
      }
      if opening.count == 1 { return .option(opening[0]) }
      throw CueStoreError.invalidAnswer(options)
    case .confirm:
      switch value.lowercased() {
      case "yes", "y", "true", "是", "好", "确认", "ok": return .confirmed(true)
      case "no", "n", "false", "否", "不", "取消": return .confirmed(false)
      default: throw CueStoreError.invalidAnswer(["是", "否"])
      }
    }
  }

  /// 停止会话正在跑的这一轮；此刻停不了（`PiSessionState.canStop`，与界面的停止按钮同一条）抛 `cannotStop`。
  public func stopSession(_ sessionID: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let session = try sessionTarget(sessionID, name: "")
    guard session.state?.canStop == true else { throw CueStoreError.cannotStop(session.target.name) }
    return try requestStop(of: session.target, on: session.host(or: host), cue: cue)
  }

  /// Cue 收掉一个会话（done 给 session）：与做完一件事同一条规则（`endUnused`），只是不除外哪件事。做不到的抛 `cannotEnd`，
  /// 在用的抛 `sessionInUse`：Cue 点名要收，得知道为什么没收。已结束的不动、返回 nil，否则返回结束请求。
  public func endIdleSession(_ sessionID: String) throws -> DeliveryRequest? {
    try write {
      guard let state = try sessionState(sessionID) else { throw CueStoreError.notFound }
      guard state.state != .known(.ended) else { return nil }
      guard state.canEnd else { throw CueStoreError.cannotEnd(state.title) }
      guard let end = try endUnused([sessionID], outside: nil, cue: true).first else { throw CueStoreError.sessionInUse(state.title) }
      return end
    }
  }

  /// 发给叶子会话的目标与会话此刻的记录。
  struct SessionTarget {
    var target: SendTarget
    var state: PiSessionState?

    /// 由哪台 Mac 执行：会话所在的那台；记录还没到时是发起的这台（`initiator`，手机为 nil）。
    func host(or initiator: String?) -> String? { state?.hostID ?? initiator }
    func host(or initiator: String) -> String { state?.hostID ?? initiator }
  }

  /// 发给会话 `sessionID` 的目标；会话记录还没到时以 `name` 称呼它。
  func sessionTarget(_ sessionID: String, name: String) throws -> SessionTarget {
    let state = try find(PiSessionState.self, PiSessionState.recordID(sessionID: sessionID))
    return SessionTarget(target: SendTarget(kind: .piSession, name: state?.title ?? name, ref: sessionID), state: state)
  }
}
