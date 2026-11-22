import CueText
import Foundation

extension CueStore {
  public func speak(
    _ content: String, to sessionID: String, name: String = "", card: UUID? = nil, config: SessionConfig? = nil,
    host: String, cue: Bool = false
  ) throws -> DeliveryRequest {
    try write {
      let session = try sessionTarget(sessionID, name: name)
      var answer: Answer?
      if let state = session.state, let question = state.answerableQuestion, let promptID = question.promptID, let kind = question.kind.known {
        if cue, CueTier.of(state, chosen: try chosenTiers()) != .full { throw CueStoreError.questionIsHis(state.title) }
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

  public func leafSession(_ leaf: UUID) throws -> String {
    let card = try requireLeaf(leaf)
    guard let sessionID = card.piSessionID else {
      if try !launchingLeaves([leaf]).isEmpty { throw CueStoreError.launching(card.heading) }
      if try !sendingLeaves([leaf]).isEmpty { throw CueStoreError.sending(card.heading) }
      throw CueStoreError.noSession(card.heading)
    }
    return sessionID
  }

  private func requestConfig(_ config: SessionConfig?, in session: SessionTarget, host: String, cue: Bool) throws {
    guard let config else { return }
    guard session.state != nil else { throw CueStoreError.cannotChangeModel(session.target.name) }
    _ = try insertDelivery(config.stored, to: session.target, on: session.host(or: host), mode: .config, cue: cue)
  }

  func say(_ content: String, to session: SessionTarget, card: UUID?, host: String, cue: Bool) throws -> DeliveryRequest {
    if cue {
      guard let state = session.state else { throw CueStoreError.sessionUnconfirmed(session.target.name) }
      try checkCueCanSpeak(in: state)
    }
    return try insertDelivery(content, to: session.target, on: session.host(or: host), mode: .send, card: card, cue: cue)
  }

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

  public func stopSession(_ sessionID: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    try write { try requestSessionStop(sessionID, host: host, cue: cue) }
  }

  func requestSessionStop(_ sessionID: String, host: String, cue: Bool = false) throws -> DeliveryRequest {
    let session = try sessionTarget(sessionID, name: "")
    if cue, let state = session.state { try requireRuntime(state) }
    guard session.state?.canStop == true else { throw CueStoreError.cannotStop(session.target.name) }
    return try requestControl(.stop, of: session.target, on: session.host(or: host), cue: cue)
  }

  public func endIdleSession(_ sessionID: String) throws -> DeliveryRequest? {
    try write {
      guard let state = try sessionState(sessionID) else { throw CueStoreError.notFound }
      if state.state == .known(.ended) {
        guard try deliveryRequests(toSession: sessionID).contains(where: \.isEnding) else { return nil }
      }
      guard try !sessionInUse(sessionID) else { throw CueStoreError.sessionInUse(state.title) }
      return try requestControl(
        .end, of: SendTarget(kind: .piSession, name: state.title, ref: sessionID), on: state.hostID, cue: true, content: DeliveryRequest.EndKind.explicit.stored)
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
