#if os(macOS)
import CryptoKit
import Foundation
import Network

/// 把一块屏变成本机网页：`GET /` 是那张页（`ScreenPage`），页面连 `/screen` 这条 WebSocket，画面往下发、手指往上送；`GET /outline` 是画面里有什么（`ScreenSource.outline`）。
/// 只听本机回环：活预览（`cuepad live`）照普通的开发服务打开它，手机经隧道看到的也是这一页。
/// 有人连着才让来源取画面（`ScreenSource.watch`、`rest`）。画面只在有改动时编，停下来后补几帧（`settle`）。
public final class ScreenServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "cuepad.screen", qos: .userInteractive)
  private let source: any ScreenSource
  private let page: Data
  private let identity: String
  private let port: UInt16
  private let listener: NWListener
  private let encoder = ScreenEncoder()
  private var viewers: [ObjectIdentifier: Viewer] = [:]
  private var dirty = false
  private var encoding = false
  private var settling = 0
  /// 编到第几帧了。
  private var turn = 0

  /// 只在 `queue` 上碰。
  private final class Viewer: @unchecked Sendable {
    let connection: NWConnection
    /// 交给连接、还没写出去的帧数。
    var queued = 0
    /// 收到过关键帧、之后的帧都接得上；跟丢了（`backlog`）就停发，等写空了从新的关键帧接。
    var synced = false
    var input = Data()
    /// 这条连接按着没抬起的手指与键：它断了替它抬起（`drop`），不然模拟器里一直按着。
    var finger: (x: Double, y: Double)?
    var keys: Set<UInt32> = []
    init(_ connection: NWConnection) { self.connection = connection }
  }

  /// 那一头慢（手机在弱网上）：攒到这么多帧没写出去就不再往里塞，画面宁可跳一下也不越拖越后。
  private static let backlog = 30
  /// 画面停下后再编几帧：码控把运动时省下的码率花在这几帧上，字从糊变清。
  private static let settle = 3
  private static let settleGap = DispatchTimeInterval.milliseconds(80)

  /// `identity` 写在每个回应的 `X-CuePad-Screen` 头里：再起一次时认得出这个口上是不是同一块屏的服务（`ScreenServer.identity(port:)`）。
  public init(source: any ScreenSource, port: UInt16, identity: String, page: String) throws {
    self.source = source
    self.port = port
    self.identity = identity
    self.page = Data(page.utf8)
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcp)
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    parameters.allowLocalEndpointReuse = true
    listener = try NWListener(using: parameters)
  }

  /// 听上了才返回；口被占着就抛。
  public func start() async throws {
    listener.newConnectionHandler = { [weak self] in self?.accept($0) }
    try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
      listener.stateUpdateHandler = { [listener] state in
        switch state {
        case .ready: ready.resume()
        case .failed(let error): ready.resume(throwing: error)
        default: return
        }
        listener.stateUpdateHandler = nil
      }
      listener.start(queue: queue)
    }
  }

  /// 这个口上的服务是哪块屏的（它的 `identity`）；没在听、不是屏的服务是 nil。
  public static func identity(port: UInt16) async -> String? {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 1
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
    request.httpMethod = "HEAD"
    let response = try? await URLSession(configuration: configuration).data(for: request).1 as? HTTPURLResponse
    return response?.value(forHTTPHeaderField: header)
  }

  private static let header = "X-CuePad-Screen"

  // MARK: 画面

  private func changed() {
    dirty = true
    pump()
  }

  private func pump() {
    guard !encoding, !viewers.isEmpty else { return }
    let key = viewers.values.contains { !$0.synced && $0.queued == 0 }
    guard dirty || key || settling > 0 else { return }
    guard let buffer = source.frame() else { return }
    if dirty { settling = Self.settle } else if !key { settling -= 1 }
    dirty = false
    encoding = true
    turn += 1
    encoder.encode(buffer, key: key) { [weak self] frame in
      guard let self else { return }
      queue.async { self.encoded(frame) }
    }
  }

  private func encoded(_ frame: ScreenEncoder.Frame?) {
    encoding = false
    if let frame { viewers.values.forEach { deliver(frame, to: $0) } }
    // 没编出来的那一次也隔一拍再来：编码器一直起不来时不空转
    if dirty, frame != nil { return pump() }
    // 这一拍里画面又动过（编过新的一帧）就不补：不然动着的时候每帧后面都跟一帧重复的
    queue.asyncAfter(deadline: .now() + Self.settleGap) { [weak self, turn] in
      if self?.turn == turn { self?.pump() }
    }
  }

  private func deliver(_ frame: ScreenEncoder.Frame, to viewer: Viewer) {
    if let description = frame.description {
      guard viewer.queued == 0 || viewer.synced else { return }
      let codec = "avc1." + description[1...3].map { String(format: "%02x", $0) }.joined()
      write(.text, Data(#"{"codec":"\#(codec)","description":"\#(description.base64EncodedString())"}"#.utf8), to: viewer)
      viewer.synced = true
    }
    guard viewer.synced else { return }
    guard viewer.queued < Self.backlog else { return viewer.synced = false }
    write(.binary, Data([frame.description == nil ? 0 : 1]) + frame.data, to: viewer)
  }

  // MARK: 连接

  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    read(connection, Data())
  }

  private func read(_ connection: NWConnection, _ head: Data) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
      guard let self, let data, error == nil else { return connection.cancel() }
      let head = head + data
      guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
        return head.count < 8192 && !complete ? self.read(connection, head) : connection.cancel()
      }
      self.route(connection, String(decoding: head[..<end.lowerBound], as: UTF8.self))
    }
  }

  private func route(_ connection: NWConnection, _ head: String) {
    var lines = head.components(separatedBy: "\r\n")
    let request = lines.removeFirst().split(separator: " ")
    let headers = Dictionary(lines.compactMap { line -> (String, String)? in
      guard let colon = line.firstIndex(of: ":") else { return nil }
      return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }) { first, _ in first }
    // 只认本机名字来的：别的网站把自己的域名解析到 127.0.0.1（DNS 重绑定）、在用户的浏览器里连这条 WebSocket 的，都挡在这里；
    // 把这一页套进自己页面里骗点击的由 X-Frame-Options 挡（`reply`）
    let mine = ["localhost:\(port)", "127.0.0.1:\(port)"]
    guard request.count == 3, let host = headers["host"], mine.contains(host), headers["origin"].map({ mine.map { "http://" + $0 }.contains($0) }) ?? true else {
      return reply(connection, "403 Forbidden")
    }
    switch (request[0], request[1]) {
    case ("GET", "/"): reply(connection, "200 OK", page)
    case ("HEAD", "/"): reply(connection, "200 OK")
    case ("GET", "/outline"):
      source.outline { [weak self] outline in
        guard let self else { return }
        queue.async { self.reply(connection, outline == nil ? "404 Not Found" : "200 OK", outline ?? Data(), type: "application/json") }
      }
    case ("GET", "/screen"):
      guard headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else { return reply(connection, "400 Bad Request") }
      let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
      let lines = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", "Sec-WebSocket-Accept: \(accept)", "", ""]
      connection.send(content: Data(lines.joined(separator: "\r\n").utf8), completion: .contentProcessed { _ in })
      let viewer = Viewer(connection)
      viewers[ObjectIdentifier(viewer)] = viewer
      if viewers.count == 1 {
        source.watch { [weak self] in
          guard let self else { return }
          queue.async { self.changed() }
        }
      }
      listen(viewer)
      pump()
    default: reply(connection, "404 Not Found")
    }
  }

  private func reply(_ connection: NWConnection, _ status: String, _ body: Data = Data(), type: String = "text/html; charset=utf-8") {
    let lines = ["HTTP/1.1 \(status)", "Content-Type: \(type)", "Content-Length: \(body.count)", "Cache-Control: no-store", "X-Frame-Options: DENY", "\(Self.header): \(identity)", "Connection: close", "", ""]
    connection.send(content: Data(lines.joined(separator: "\r\n").utf8) + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
  }

  // MARK: WebSocket（RFC 6455，只用到的那一小块：服务端发不分片的帧，收网页发来的短文本）

  private enum Opcode: UInt8 { case text = 1, binary = 2, close = 8, ping = 9, pong = 10 }

  private func write(_ opcode: Opcode, _ payload: Data, to viewer: Viewer) {
    var frame = Data([0x80 | opcode.rawValue])
    switch payload.count {
    case ..<126: frame.append(UInt8(payload.count))
    case ..<65536: frame.append(contentsOf: [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
    default: frame.append(contentsOf: [127] + (0..<8).reversed().map { UInt8(truncatingIfNeeded: payload.count >> ($0 * 8)) })
    }
    viewer.queued += 1
    viewer.connection.send(content: frame + payload, completion: .contentProcessed { [weak self, weak viewer] error in
      guard let self, let viewer else { return }
      viewer.queued -= 1
      if error != nil { return self.drop(viewer) }
      if viewer.queued == 0, !viewer.synced { self.pump() }
    })
  }

  private func listen(_ viewer: Viewer) {
    viewer.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak viewer] data, _, complete, error in
      guard let self, let viewer else { return }
      guard let data, error == nil, !complete else { return self.drop(viewer) }
      viewer.input.append(data)
      while let (opcode, payload) = Self.frame(&viewer.input) {
        switch opcode {
        case .text: if let input = Self.input(payload) { self.forward(input, from: viewer) }
        case .ping: self.write(.pong, payload, to: viewer)
        case .close: return self.drop(viewer, answering: payload)
        default: break
        }
      }
      // 网页的帧最多几 KB（一段字，`ScreenPage` 的 `type` 切过）：攒到这么多还凑不成一帧的不是它
      viewer.input.count < 4096 ? self.listen(viewer) : self.drop(viewer)
    }
  }

  private func forward(_ input: ScreenInput, from viewer: Viewer) {
    switch input {
    case .touch(let phase, let x, let y): viewer.finger = phase == .up ? nil : (x, y)
    case .key(let usage, let down): if down { viewer.keys.insert(usage) } else { viewer.keys.remove(usage) }
    case .secondary, .wheel, .text, .focus, .fill: break
    }
    source.send(input)
  }

  /// `answering`：那头先发了 Close，把它的那一帧（带着关闭码）回过去再断，不回的话它记成异常断开。
  private func drop(_ viewer: Viewer, answering: Data? = nil) {
    guard viewers.removeValue(forKey: ObjectIdentifier(viewer)) != nil else { return }
    if viewers.isEmpty { source.rest() }
    if let finger = viewer.finger { source.send(.touch(.up, x: finger.x, y: finger.y)) }
    viewer.keys.forEach { source.send(.key(usage: $0, down: false)) }
    let connection = viewer.connection
    // 控制帧的内容不过 125 字节
    guard let answer = answering?.prefix(125) else { return connection.cancel() }
    connection.send(content: Data([0x80 | Opcode.close.rawValue, UInt8(answer.count)]) + answer, completion: .contentProcessed { _ in connection.cancel() })
  }

  /// 从头上取下一整帧；不够一帧是 nil。客户端的帧都带掩码；长度写到两字节那一档，八字节那一档的永远凑不成，`listen` 攒满了断开它。
  private static func frame(_ input: inout Data) -> (Opcode, Data)? {
    let bytes = [UInt8](input.prefix(8))
    guard bytes.count >= 2, bytes[1] & 0x80 != 0 else { return nil }
    var length = Int(bytes[1] & 0x7F), start = 2
    if length == 126 {
      guard bytes.count >= 4 else { return nil }
      (length, start) = (Int(bytes[2]) << 8 | Int(bytes[3]), 4)
    }
    guard length != 127, input.count >= start + 4 + length else { return nil }
    let all = [UInt8](input.prefix(start + 4 + length)), mask = all[start..<start + 4]
    let payload = Data(all[(start + 4)...].enumerated().map { $1 ^ mask[mask.startIndex + $0 % 4] })
    input.removeFirst(start + 4 + length)
    return (Opcode(rawValue: bytes[0] & 0x0F) ?? .pong, payload)
  }

  /// 一下滚轮最多滚这么多屏。
  private static let maxWheel = 16.0

  private static func input(_ payload: Data) -> ScreenInput? {
    guard let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let kind = message["t"] as? String else { return nil }
    if kind == "text", let text = message["s"] as? String { return .text(text) }
    if kind == "focus", let id = message["i"] as? Int { return .focus(id) }
    if kind == "fill", let id = message["i"] as? Int, let text = message["s"] as? String { return .fill(id, text) }
    if kind == "key", let usage = message["u"] as? Int, (4...231).contains(usage), let down = message["d"] as? Bool { return .key(usage: UInt32(usage), down: down) }
    // 来源照这些数造事件、算整数：出了界的不往下送
    guard let x = message["x"] as? Double, let y = message["y"] as? Double, (0...1).contains(x), (0...1).contains(y) else { return nil }
    if kind == "menu" { return .secondary(x: x, y: y) }
    if kind == "wheel", let dx = message["dx"] as? Double, let dy = message["dy"] as? Double, abs(dx) <= maxWheel, abs(dy) <= maxWheel {
      return .wheel(x: x, y: y, dx: dx, dy: dy)
    }
    if kind == "wheel" { return nil }
    return ScreenInput.Phase(rawValue: kind).map { .touch($0, x: x, y: y) }
  }
}
#endif
