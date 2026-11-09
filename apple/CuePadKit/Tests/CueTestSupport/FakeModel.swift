#if os(macOS)
import Foundation
import Network
import Synchronization

/// 真 Agent 连的假模型：本进程里的 HTTP 服务（127.0.0.1 的空闲端口），零网络、结果确定。一个用例起一个，按请求的路径说三种协议：
/// Chat Completions（`/chat/completions`：Pi、OpenCode）、Responses（`/responses`：Codex、Grok）、Anthropic Messages（`/messages`：Claude Code、dsh），
/// 都是流式（请求没要流式时回整条）。每个请求连同没认出的路径都记进 `requests`：断言 Agent 真把这句话交给了模型。
///
/// 剧本：`on` 登记的规则，后登记的先认；都不认回 `ECHO <prompt>`（带图时再加 ` IMAGES[<mime>:<base64 长度>,…]`）。
/// 规则只看这一个请求（`FakeRequest.prompt` 是最近一条你的话，`step` 是那之后已调过几次工具），不按到达先后数：
/// 几个会话同时请求、Agent 重试同一步，各自拿到的都是自己那一步（共用一个游标会错配）。
public final class FakeModel: Sendable {
  public let port: UInt16
  /// 每次回答报的输入用量（token），nil 时按请求里对话的字数估（每 4 个字一个，同 Pi 自己的估法）；输出总报 5
  public let usage: Int?
  private let listener: NWListener
  private let queue = DispatchQueue(label: "fake-model")
  private struct State {
    var rules: [Rule] = []
    var requests: [FakeRequest] = []
    var open: [ObjectIdentifier: NWConnection] = [:]
  }
  private let state = Mutex(State())
  private struct Rule {
    let match: @Sendable (FakeRequest) -> Bool
    let reply: @Sendable (FakeRequest) -> FakeReply
  }

  public var baseURL: String { "http://127.0.0.1:\(port)" }
  public var requests: [FakeRequest] { state.withLock { $0.requests } }

  public init(usage: Int? = nil) async throws {
    self.usage = usage
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    let (ready, signal) = AsyncStream<UInt16?>.makeStream()
    listener.stateUpdateHandler = { [listener] state in
      switch state {
      case .ready: signal.yield(listener.port?.rawValue)
      case .failed, .cancelled: signal.yield(nil)
      default: break
      }
    }
    let (connections, accept) = AsyncStream<NWConnection>.makeStream()
    listener.newConnectionHandler = { accept.yield($0) }
    listener.start(queue: queue)
    var port: UInt16?
    for await value in ready { port = value; break }
    guard let port else { throw URLError(.cannotConnectToHost) }
    self.port = port
    Task { [weak self] in
      for await connection in connections { self?.serve(connection) }
    }
  }

  deinit { stop() }

  /// 停止监听并断开所有连接（停在闸门上、说到一半的随之结束）。
  public func stop() {
    listener.cancel()
    for connection in state.withLock({ state in defer { state.open = [:] }; return Array(state.open.values) }) { connection.cancel() }
  }

  /// 最近一条你的话里有 `prompt` 时按 `steps` 答：第 n 步（`FakeRequest.step`）用第 n 个，超出的用最后一个。
  public func on(_ prompt: String, _ steps: FakeReply...) {
    on({ $0.prompt.contains(prompt) }) { steps[min($0.step, steps.count - 1)] }
  }

  public func on(_ prompt: String, reply: @escaping @Sendable (FakeRequest) -> FakeReply) {
    on({ $0.prompt.contains(prompt) }, reply: reply)
  }

  /// 同上，只答前 `times` 个认出的请求，之后的交给别的规则（如第一次出错、重试照常）
  public func on(_ prompt: String, times: Int, _ steps: FakeReply...) {
    let left = Budget(times)
    on({ $0.prompt.contains(prompt) && left.take() }) { steps[min($0.step, steps.count - 1)] }
  }

  public func on(_ match: @escaping @Sendable (FakeRequest) -> Bool, reply: @escaping @Sendable (FakeRequest) -> FakeReply) {
    state.withLock { $0.rules.insert(Rule(match: match, reply: reply), at: 0) }
  }

  public func gate() -> FakeGate { FakeGate() }

  func reply(to request: FakeRequest) -> FakeReply {
    let rules = state.withLock { state in
      state.requests.append(request)
      return state.rules
    }
    if let rule = rules.first(where: { $0.match(request) }) { return rule.reply(request) }
    let images = request.images.isEmpty ? "" : " IMAGES[\(request.images.joined(separator: ","))]"
    return .say("ECHO \(request.prompt)\(images)")
  }

  // MARK: HTTP

  private func serve(_ connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    state.withLock { $0.open[id] = connection }
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.state.withLock { _ = $0.open.removeValue(forKey: id) }
      default: break
      }
    }
    connection.start(queue: queue)
    Task {
      guard let message = await HTTPMessage.read(from: connection) else { return connection.cancel() }
      await respond(to: message, on: Wire(connection: connection))
    }
  }

  private func respond(to message: HTTPMessage, on wire: Wire) async {
    defer { wire.close() }
    let request = FakeRequest(path: message.path, method: message.method, body: message.body)
    guard request.api != .other else {
      _ = reply(to: request)
      let found = message.method == "GET" && message.path.hasSuffix("/models")
      return await wire.json(status: found ? 200 : 404, found ? #"{"object":"list","data":[]}"# : #"{"error":{"message":"not found"}}"#)
    }
    if message.path.hasSuffix("/count_tokens") {
      _ = reply(to: request)
      return await wire.json(status: 200, #"{"input_tokens":\#(usage ?? request.estimatedTokens)}"#)
    }
    var answer = reply(to: request)
    while case .held(let gate, let next) = answer {
      guard await gate.pass(unless: wire.disconnected) else { return }
      answer = next
    }
    await Encoder(api: request.api, request: request, usage: usage ?? request.estimatedTokens, wire: wire).send(answer)
  }
}

private final class Budget: Sendable {
  private let left: Mutex<Int>
  init(_ times: Int) { left = Mutex(times) }
  func take() -> Bool { left.withLock { guard $0 > 0 else { return false }; $0 -= 1; return true } }
}

/// 剧本的一步。`call` 的工具名按请求里的工具清单补全：Agent 给 MCP 工具加的前缀（`mcp__cuepad__echo`、`cuepad_echo`）不用写。
public indirect enum FakeReply: Sendable {
  case say(String)
  case call(String, [String: any Sendable])
  /// 回 HTTP 错误（默认 400），`message` 是错误原文
  case fail(String, status: Int = 400)
  /// 先说这几段，然后不说完也不结束，直到 Agent 断开（停下这一轮）
  case stream([String])
  /// 先说这几段，停在闸门上（请求不结束）；放行后收尾。只有 Responses 协议实现（Grok 的搁浅插话用）；Agent 先断开就不收尾
  case streamUntil([String], FakeGate)
  /// 停在闸门上：放行一次后照 `then` 答；Agent 先断开（停下这一轮）就不答，也不占用放行
  case held(FakeGate, then: FakeReply)

  /// 一直不答，直到 Agent 断开
  public static var hang: FakeReply { .held(FakeGate(), then: .say("")) }
}

/// 闸门：请求停在这里，等测试放行（`open`）或 Agent 断开；先放行后停住也算。
public final class FakeGate: Sendable {
  private struct State {
    var held = 0
    var seen = 0
    var permits = 0
    var always = false
    var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// 还没排进 `waiting` 就断开了的
    var gone: Set<UUID> = []
  }
  private let state = Mutex(State())

  public init() {}

  /// 一共停住过几次
  public var held: Int { state.withLock { $0.held } }
  /// 正停着的
  public var waiting: Int { state.withLock { $0.waiting.count } }

  /// 等到又有一个请求停住（从上次等到的往后数）
  public func reached() async throws {
    let wanted = state.withLock { $0.seen += 1; return $0.seen }
    try await eventually("假模型停在闸门上（第 \(wanted) 次）") { self.held >= wanted }
  }

  /// 放行一次
  public func open() {
    let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
      guard let first = state.waiting.first else { state.permits += 1; return nil }
      state.waiting[first.key] = nil
      return first.value
    }
    waiter?.resume(returning: true)
  }

  /// 之后的停住都当场放行（连同正停着的）
  public func openForever() {
    let waiters = state.withLock { state in
      state.always = true
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for waiter in waiters { waiter.resume(returning: true) }
  }

  /// 放行时为 true；`disconnected` 先结束（Agent 断开）时为 false
  func pass(unless disconnected: @escaping @Sendable () async -> Void) async -> Bool {
    let id = UUID()
    let watcher = Task {
      await disconnected()
      state.withLock { state -> CheckedContinuation<Bool, Never>? in
        guard let waiter = state.waiting.removeValue(forKey: id) else { state.gone.insert(id); return nil }
        return waiter
      }?.resume(returning: false)
    }
    defer { watcher.cancel() }
    return await withCheckedContinuation { continuation in
      let ready = state.withLock { state -> Bool? in
        state.held += 1
        if state.gone.remove(id) != nil { return false }
        if state.always { return true }
        if state.permits > 0 { state.permits -= 1; return true }
        state.waiting[id] = continuation
        return nil
      }
      if let ready { continuation.resume(returning: ready) }
    }
  }
}
#endif
