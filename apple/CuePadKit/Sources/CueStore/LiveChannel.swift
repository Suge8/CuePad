#if os(macOS)
import Darwin
import Foundation

public enum LiveChannel {
  /// 库目录下的 `live.sock`；`sun_path` 只有 104 字节，目录太深（测试的临时库）放不下时换到本用户的临时目录（`confstr`，不随环境变量 TMPDIR 变），
  /// 文件名带库路径的散列。命令行与 App 各自算出同一个。
  public static func socketPath(databasePath: String) -> String {
    let beside = (databasePath as NSString).deletingLastPathComponent + "/live.sock"
    guard beside.utf8.count >= capacity else { return beside }
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let temporary = length > 0 ? String(decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self) : NSTemporaryDirectory()
    let hash = databasePath.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    return (temporary as NSString).appendingPathComponent("cuepad-live-\(String(hash, radix: 16)).sock")
  }

  private static let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

  public struct Request: Codable, Sendable, Equatable {
    public var session: String
    public var op: Op

    public init(session: String, op: Op) {
      self.session = session
      self.op = op
    }
  }

  /// 命令行能交给 App 的每一件事（`cuepad live` 与它的动词）：两头都只认这一份，加一件两头一起编。
  public enum Op: Codable, Sendable, Equatable {
    /// 不带地址：用 App 认出的这个会话的服务。
    case open(URL?)
    case snapshot(ref: String? = nil, interactive: Bool = false, find: String? = nil)
    case click(ref: String)
    case fill(ref: String, text: String)
    case press(key: String, ref: String? = nil)
    case wait(Awaited, timeout: Double)
    case screenshot(ref: String? = nil)
    case console(all: Bool = false)
    case upload(ref: String, files: [Upload])
    case eval(code: String)

    public var patience: Duration {
      if case .wait(_, let timeout) = self { .seconds(timeout + 60) } else { .seconds(60) }
    }
  }

  public enum Awaited: Codable, Sendable, Equatable {
    case text(String), selector(String), url(String)
  }

  public struct Upload: Codable, Sendable, Equatable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) { (self.name, self.data) = (name, data) }
  }

  public static let uploadLimit = 32_000_000
  static let requestLimit = 48_000_000

  public struct Reply: Codable, Sendable, Equatable {
    public var text: String
    public var failed: Bool
    public var info: Info?
    public var file: Data?

    public static func done(_ text: String, _ info: Info? = nil, file: Data? = nil) -> Reply { Reply(text: text, failed: false, info: info, file: file) }
    public static func refused(_ text: String) -> Reply { Reply(text: text, failed: true, info: nil, file: nil) }
  }

  public struct Info: Codable, Sendable, Equatable {
    public var url: String?
    public var title: String?
    public var width: Int?
    public var height: Int?
    public var bytes: Int?

    public init(url: String? = nil, title: String? = nil, width: Int? = nil, height: Int? = nil, bytes: Int? = nil) {
      (self.url, self.title, self.width, self.height, self.bytes) = (url, title, width, height, bytes)
    }
  }

  public enum Failure: Error, Equatable {
    case notListening
    /// 不让连：命令跑在沙箱里（Codex 的 workspace-write 实测 connect 回 EPERM）。
    case sandboxed
    case timedOut
    case broken(String)
  }

  public static func ask(_ request: Request, path: String) throws(Failure) -> Reply {
    let timeout = request.op.patience
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .broken("socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var address = try address(path)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw errno == EPERM || errno == EACCES ? .sandboxed : .notListening }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    limit(fd, SO_RCVTIMEO, timeout)
    let body: Data
    do { body = try JSONEncoder().encode(request) + Data("\n".utf8) } catch { throw .broken("\(error)") }
    guard writeAll(fd, body) else { throw .broken("写请求：\(String(cString: strerror(errno)))") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let got = read(fd, &buffer, buffer.count)
      if got == 0 { break }
      guard got > 0 else { throw errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .broken("读应答：\(String(cString: strerror(errno)))") }
      data.append(buffer, count: got)
    }
    do { return try JSONDecoder().decode(Reply.self, from: data) } catch { throw .broken("应答读不懂（\(data.count) 字节）") }
  }

  public final class Server: Sendable {
    private let fd: Int32
    private let path: String
    private let source: any DispatchSourceRead

    public init(path: String, store: CueStore, handle: @escaping @Sendable (Request) async -> Reply) throws {
      var address = try LiveChannel.address(path)
      unlink(path)
      let listening = socket(AF_UNIX, SOCK_STREAM, 0)
      guard listening >= 0 else { throw Failure.broken("socket: \(String(cString: strerror(errno)))") }
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listening, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard bound == 0, chmod(path, 0o600) == 0, listen(listening, 32) == 0 else {
        let reason = String(cString: strerror(errno))
        close(listening)
        throw Failure.broken("听 \(path)：\(reason)")
      }
      _ = fcntl(listening, F_SETFL, fcntl(listening, F_GETFL) | O_NONBLOCK)
      fd = listening
      self.path = path
      source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "cuepad.live.accept"))
      source.setEventHandler {
        while true {
          let client = accept(listening, nil, nil)
          guard client >= 0 else { return }
          // accept 出来的连接随听的那个是非阻塞的：读写都按阻塞来（各有超时）
          _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
          Task { await LiveChannel.converse(client, store: store, handle: handle) }
        }
      }
      source.resume()
    }

    deinit {
      source.cancel()
      close(fd)
      unlink(path)
    }
  }

  private static func converse(_ client: Int32, store: CueStore, handle: @escaping @Sendable (Request) async -> Reply) async {
    defer { close(client) }
    var on: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let reply: Reply
    switch await readRequest(client) {
    case .failure(let text):
      reply = .refused(text)
    case .success(let request):
      if let refusal = await admit(request, peer: peer(client), store: store) {
        reply = .refused(refusal)
      } else {
        let work = Task { await handle(request) }
        let hangup = watchHangup(client) { work.cancel() }
        reply = await work.value
        hangup.cancel()
      }
    }
    guard let data = try? JSONEncoder().encode(reply) else { return }
    limit(client, SO_SNDTIMEO, .seconds(5))
    _ = writeAll(client, data)
  }

  static func admit(_ request: Request, peer: pid_t?, store: CueStore) async -> String? {
    guard !request.session.isEmpty else { return "请求里没有会话" }
    let owner: LiveServers.Owner
    do { owner = try await store.liveOwner(request.session) } catch { return "读不出会话 \(request.session)：\(error)" }
    guard let process = owner.process, process.isRunning else { return nil }
    guard let peer, LiveServers.descends(peer, from: process) else {
      return "会话 \(request.session) 的 Agent 进程（pid \(process.pid)）底下没有这条命令：环境变量里的会话不是发这条命令的那个，只能操作自己会话的活预览"
    }
    return nil
  }

  private static func peer(_ fd: Int32) -> pid_t? {
    var pid: pid_t = 0
    var size = socklen_t(MemoryLayout<pid_t>.size)
    return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
  }

  private enum Read { case success(Request), failure(String) }

  @concurrent private static func readRequest(_ fd: Int32) async -> Read {
    limit(fd, SO_RCVTIMEO, .seconds(5))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let got = read(fd, &buffer, buffer.count)
      guard got > 0 else { return .failure("请求没读完") }
      data.append(buffer, count: got)
      if buffer[..<got].contains(UInt8(ascii: "\n")) { break }
      guard data.count < requestLimit else { return .failure("请求太大") }
    }
    let line = data.prefix { $0 != UInt8(ascii: "\n") }
    guard let request = try? JSONDecoder().decode(Request.self, from: line) else { return .failure("请求读不懂：命令行与 App 不是同一版") }
    return .success(request)
  }

  private static func watchHangup(_ fd: Int32, _ gone: @escaping @Sendable () -> Void) -> any DispatchSourceRead {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
    source.setEventHandler {
      var byte: UInt8 = 0
      if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0 {
        gone()
        source.cancel()
      }
    }
    source.resume()
    return source
  }

  private static func limit(_ fd: Int32, _ option: Int32, _ duration: Duration) {
    let (seconds, attoseconds) = duration.components
    var value = timeval(tv_sec: Int(seconds), tv_usec: Int32(attoseconds / 1_000_000_000_000))
    setsockopt(fd, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
  }

  private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let wrote = write(fd, raw.baseAddress! + offset, raw.count - offset)
        guard wrote > 0 else { return false }
        offset += wrote
      }
      return true
    }
  }

  /// `sun_path` 只有 104 字节：库目录太深时如实报错，不截断成别人的路径。
  private static func address(_ path: String) throws(Failure) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else { throw .broken("套接字路径超过 \(capacity - 1) 字节：\(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    return address
  }
}
#endif
