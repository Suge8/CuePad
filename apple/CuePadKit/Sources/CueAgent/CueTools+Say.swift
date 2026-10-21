import CueStore
import CueText
import Foundation

extension CueTools {
  /// `agent` 的取值。
  static let agents = AgentKind.allCases.map(\.rawValue).joined(separator: " / ")

  func say(_ args: Args) async throws -> Result {
    let target = try await speaker(args)
    let host = try await host()
    let config = try await config(args, of: target.session)
    let switched = config.map { "先换成 " + [$0.model.map { "\($0.provider)/\($0.id)" }, $0.thinking?.rawValue].compactMap { $0 }.joined(separator: " ") + "，再" } ?? ""
    let request = try await store.speak(
      try args.required("text"), to: target.session, card: target.card, config: config, host: host, cue: true)
    let what = request.mode == .known(.answer) ? "\(switched)回答\(target.label)的提问" : "\(switched)对\(target.label)说"
    return try await spoken(request, what, tail: target.short)
  }

  /// say、stop 对的会话：给 task 是它在做的叶子绑着的会话（带上叶子），给 session 是那个会话。`label` 是工具结果里对它的称呼。
  func speaker(_ args: Args) async throws -> (session: String, card: UUID?, label: String, short: String) {
    if let ref = args.string("task") {
      let leaf = try await workingLeaf(ref)
      return (try await store.leafSession(leaf.id), leaf.id, "「\(leaf.heading)」的会话", leaf.id.shortID)
    }
    guard let ref = args.string("session") else { throw Failure("要给 task 或 session") }
    let session = try await session(ref)
    return (session.sessionID, nil, "会话「\(session.title)」", session.shortID)
  }

  /// 说的话写下后等结果，至多到写下后 `wait`：结果按说的话那条规则（`Speech`）读——已送达、没送到（工具结果标成出错，带 Mac 报的原因），
  /// 或还在路上（如实说还没送达；之后没送到会写进下一轮的变化，见 `CueChange.Kind.undelivered`）。`what` 是做了什么。
  func spoken(_ request: DeliveryRequest, _ what: String, tail short: String) async throws -> Result {
    let latest = try await settled(request)
    let tail = "（\(short)）"
    switch Speech.trip(latest, at: .always()) {
    case .delivered:
      return .ok("\(what)：已送达。\(tail)")
    case .failed(let failure):
      let reason = if case .reported(let reason) = failure { reason } else { DeliveryRequest.unexplainedFailure }
      return Result(text: "\(what)：没送到——\(reason)\(tail) \(Self.undeliveredMark(request.id))", isError: true)
    case .sending:
      return .ok("\(what)：已发出，还没送达，结果会写进变化。\(tail)")
    }
  }

  /// 说的话没送到时写在工具结果末尾的请求标识。工具写出回应不等于 Cue 看到了（大脑可能正在这时没了）：值班的管理器在这一轮
  /// 好好做完时，从这一轮收到的出错工具结果里认出它们，记下已告诉 Cue（`CueStore.markCueTold`），别的失败照样进下一轮的变化。
  static func undeliveredMark(_ request: UUID) -> String { "[请求 \(request.uuidString.lowercased())]" }

  /// 一条出错的工具结果里告诉了 Cue 的没送到的请求（`undeliveredMark`）。
  public static func undeliveredRequests(in result: String) -> [UUID] {
    result.matches(of: /\[请求 ([0-9a-f-]{36})\]/).compactMap { UUID(uuidString: String($0.1)) }
  }

  /// 等请求有结果，至多到写下后 `wait`；到点还没结果返回此刻的记录。等的是别的进程（执行它的 Mac 上的 App）写回的结果：
  /// 库的变化订阅跨进程（`CueStore.outcome`），不轮询；到点用一次可取消的睡眠——等多久本身就是这里的规则。
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

  /// say 带的 model、effort（说话与作答之前先换上）；model 的写法同 start，只写 id 时提供方按会话是哪家补。都没带为 nil。
  private func config(_ args: Args, of session: String) async throws -> PiConfig? {
    let effort = try Self.effort(args)
    guard let raw = args.string("model") else { return effort.map { PiConfig(thinking: $0) } }
    let agent = try await store.piSessions(sessionIDs: [session])[session]?.state.agent.known
    return PiConfig(model: try (agent ?? .pi).requiredModelKey(raw), thinking: effort)
  }
}
