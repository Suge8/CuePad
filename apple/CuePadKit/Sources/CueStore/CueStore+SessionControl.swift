import CueText
import Foundation

extension CueStore {
  /// 界面的回复框与 Cue 的 say 共用这一条。会话在等 CuePad 能代答的提问时，这句就是答案（`answerValue`），答不上抛 `invalidAnswer`，什么都不写；否则发出（规则见 `say`）。带 `config` 时先请会话换上，换不了模型抛 `cannotChangeModel`，什么都不写。会话已结束也照说：执行它的 Mac 先恢复它。你的话让绑着这个会话的已完成任务回到进行中，Cue 的话不改任务的状态（`insertDelivery`）。`name` 与 `host` 是会话记录还没到时的称呼与执行的 Mac。
  public func speak(
    _ content: String, to sessionID: String, name: String = "", card: UUID? = nil, config: SessionConfig? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write {
      let session = try sessionTarget(sessionID, name: name)
      var answer: Answer?
      if let question = session.state?.answerableQuestion, let promptID = question.promptID, let kind = question.kind.known {
        let value = CueFormat.plainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
        answer = Answer(promptID: promptID, value: try Self.answerValue(value, kind: kind, options: question.options, allowsOther: question.allowsOther, leading: cue))
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

  /// 必须在写事务内、写别的之前调用：抛错时什么都没写。记录没到不换，抛 `cannotChangeModel`。
  private func requestConfig(_ config: SessionConfig?, in session: SessionTarget, host: String, cue: Bool) throws {
    guard let config else { return }
    guard session.state != nil else { throw CueStoreError.cannotChangeModel(session.target.name) }
    _ = try insertDelivery(config.stored, to: session.target, on: session.host(or: host), mode: .config, cue: cue)
  }

  /// Cue 这会儿说不了就抛 `cannotSpeakNow`、什么都不写：会打断他发起的那一轮（`checkCueCanSpeak`），那一轮停下也归他（`leaveHisStops`），不叫醒 Cue。正文原样写：收不了图片的会话由 Mac 交出时把图片写成路径。必须在写事务内调用。
  func say(_ content: String, to session: SessionTarget, card: UUID?, host: String, cue: Bool) throws -> DeliveryRequest {
    if cue {
      guard let state = session.state else { throw CueStoreError.sessionUnconfirmed(session.target.name) }
      try checkCueCanSpeak(in: state)
    }
    return try insertDelivery(content, to: session.target, on: session.host(or: host), mode: .send, card: card, cue: cue)
  }

  /// 唯一的一处：“他说的”标记、他那一轮里 Cue 不插嘴、停下归谁接手都只认它。扩展投进来的机器消息（FireCode 交回子代理结果、审查结论）开的轮不另算：它是那句话派出去的活交回来了，从那句起到真正歇下是一件事。会话里还没有你一方的话为 nil。
  func turnOpener(_ sessionID: String) throws -> TurnOpener? {
    guard let last = try select(
      ChatMessage.self, where: "sessionID = ? AND role = '\(ChatRole.user.rawValue)'", [sessionID], orderBy: "seq DESC, id DESC", limit: 1
    ).first else { return nil }
    switch last.source(in: try deliverySources(among: [last.deliveryID].compactMap(\.self))) {
    case .cue: return .cue
    case .user: return .user
    case .unconfirmed: return .unconfirmed
    }
  }

  enum TurnOpener { case user, cue, unconfirmed }

  /// 收自己写的回答的以外，Cue 说的（`leading`）开头正好是一个选项、后面紧跟标点或空白就按那个选项答，后面的说明不送，工具结果会告诉它；你在回复框里写的不这样截，免得说明悄悄丢掉。只认开头：说明里才提到选项（“不换，仍按 A”）猜不准。
  private static func answerValue(_ value: String, kind: QuestionKind, options: [String], allowsOther: Bool, leading: Bool) throws -> AnswerValue {
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

  /// Cue 停的先看此刻在做什么确认过没有（`requireRuntime`）：没确认时说的是那台 Mac 不在线或还没报，不说"没在跑"。
  public func stopSession(_ sessionID: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestSessionStop(sessionID, host: host, cue: cue) }
  }

  func requestSessionStop(_ sessionID: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let session = try sessionTarget(sessionID, name: "")
    if cue, let state = session.state { try requireRuntime(state) }
    guard session.state?.canStop == true else { throw CueStoreError.cannotStop(session.target.name) }
    return try requestControl(.stop, of: session.target, on: session.host(or: host), cue: cue)
  }

  /// 在用的抛 `sessionInUse`：Cue 点名要收，得知道为什么没收。已结束且无待核对结束请求才返回 nil；否则明确投送，不用 ended 快照代替执行结果。
  public func endIdleSession(_ sessionID: String) throws -> DeliveryRequest? {
    try write {
      guard let state = try sessionState(sessionID) else { throw CueStoreError.notFound }
      if state.state == .known(.ended) {
        let unresolved = try deliveryRequests(toSession: sessionID).contains {
          $0.mode == .known(.end) && $0.handledBy != nil && ($0.isOpen || $0.status == .known(.unconfirmed))
        }
        guard unresolved else { return nil }
      }
      guard try db.first(Self.usedElsewhere, [sessionID, nil as UUID?], { _ in true }) == nil else { throw CueStoreError.sessionInUse(state.title) }
      return try requestControl(.end, of: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, cue: true)
    }
  }

  struct SessionTarget {
    var target: SendTarget
    var state: SessionState?

    func host(or initiator: String?) -> String? { state?.hostID ?? initiator }
    func host(or initiator: String) -> String { state?.hostID ?? initiator }
  }

  func sessionTarget(_ sessionID: String, name: String) throws -> SessionTarget {
    let state = try find(SessionState.self, SessionState.recordID(sessionID: sessionID))
    return SessionTarget(target: SendTarget(kind: .piSession, name: state?.title ?? name, ref: sessionID), state: state)
  }
}
