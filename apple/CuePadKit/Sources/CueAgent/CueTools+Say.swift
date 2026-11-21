import CueStore
import CueText
import Foundation

extension CueTools {
  static let agents = AgentKind.allCases.map(\.rawValue).joined(separator: " / ")

  func say(_ args: Args) async throws -> Result {
    let target = try await speaker(args)
    let host = try await host()
    let config = try await config(args, of: target.session, host: host)
    let switched = config.map { "先换成 " + [$0.model.map { "\($0.provider)/\($0.id)" }, $0.thinking?.rawValue].compactMap { $0 }.joined(separator: " ") + "，再" } ?? ""
    let text = try args.required("text")
    let request = try await store.speak(text, to: target.session, card: target.card, config: config, host: host, cue: true)
    var what = request.mode == .known(.answer) ? "\(switched)回答\(target.label)的提问" : "\(switched)对\(target.label)说"
    if case .option(let option)? = request.answer?.value, Self.saidMore(text, than: option) { what += "（按开头的选项「\(option)」作答，后面的话没送）" }
    return try await spoken(request, what, tail: target.short, from: host)
  }

  private static func saidMore(_ text: String, than option: String) -> Bool {
    let value = CueFormat.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
    return Int(value) == nil && value.caseInsensitiveCompare(option) != .orderedSame
  }

  func speaker(_ args: Args) async throws -> (session: String, card: UUID?, label: String, short: String) {
    let leaf: Card
    switch try await references.place(args) {
    case .session(let session)?: return (session.sessionID, nil, "会话「\(session.title)」", session.shortID)
    case .task(let card)?: leaf = try await store.workingLeaf(of: card.id)
    case nil: throw Failure("要给 task 或 session")
    }
    return (try await store.leafSession(leaf.id), leaf.id, "「\(leaf.heading)」的会话", leaf.id.shortID)
  }

  func spoken(_ request: DeliveryRequest, _ what: String, tail short: String, from host: String) async throws -> Result {
    let latest = try await settled(request)
    let tail = "（\(short)）\n\(CueToolReceipt(.request, request.id).mark)"
    let moment = Speech.Moment.always(localHost: host)
    switch Speech.trip(latest, at: moment) {
    case .preparing(let reason):
      return .ok("\(what)：\(reason)。这是原请求，不要重复发送。\(tail)")
    case .delivered:
      return .ok("\(what)：已送达。\(tail)")
    case .failed(.reported(let reason)):
      return Result(text: "\(what)：没送到——\(reason)\(tail)", isError: true)
    case .sending, .sent, .unconfirmed:
      return .ok("\(what)：送达尚未确认，可能已经执行；不要自动重发。若收到后续回执或消息，再据实判断。\(tail)")
    }
  }

  private func settled(_ request: DeliveryRequest) async throws -> DeliveryRequest {
    let left = request.createdAt.addingTimeInterval(wait).timeIntervalSinceNow
    let done = try await withThrowingTaskGroup(of: DeliveryRequest?.self) { group in
      group.addTask { [store] in try await store.outcome(of: request) }
      group.addTask {
        if left > 0 { try await Task.sleep(for: .seconds(left)) }
        return nil
      }
      defer { group.cancelAll() }
      return try await group.next() ?? nil
    }
    if let done { return done }
    return try await store.latest(of: request) ?? request
  }

  private func config(_ args: Args, of session: String, host: String) async throws -> SessionConfig? {
    let effort = try Self.effort(args)
    guard let raw = args.string("model") else { return effort.map { SessionConfig(thinking: $0) } }
    let agent = try await store.sessionItems(sessionIDs: [session])[session]?.state.agent.known
    return SessionConfig(model: try await store.cueModelKey(raw, of: agent ?? .pi, host: host, session: session), thinking: effort)
  }
}
