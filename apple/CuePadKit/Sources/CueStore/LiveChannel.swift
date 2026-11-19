#if os(macOS)
import Darwin
import Foundation

/// `cuepad live snapshot|click|…` 与开着这份库的 App 之间的一问一答：库目录下的 Unix 套接字 `live.sock`，文件 0600、只有本用户连得上，不过网络。
/// 一条连接一问一答：请求是一行 JSON，应答是一份 JSON、写完就关。客户端写完请求不半关：服务端之后读到 EOF 就是对方走了（Ctrl-C、超时、被杀），
/// 在做的那一件随之取消。没用资料库的请求-应答（`outcome(of:)` 那条）：快照是一次性的大块临时数据，进会同步的库要加表，沙箱里的 Agent 还写不了库。
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
    public var op: String
    public var args: Args

    public init(session: String, op: String, args: Args = Args()) {
      self.session = session
      self.op = op
      self.args = args
    }
  }

  /// 各动词的参数并在一处：每个动词只用其中几个（`cuepad live <动词> --help`）。
  public struct Args: Codable, Sendable, Equatable {
    public var ref: String?
    public var text: String?
    public var key: String?
    public var selector: String?
    public var url: String?
    public var timeout: Double?
    public var out: String?
    public var files: [String]?
    public var all: Bool?
    public var interactive: Bool?
    public var find: String?
    public var code: String?

    public init(
      ref: String? = nil, text: String? = nil, key: String? = nil, selector: String? = nil, url: String? = nil, timeout: Double? = nil,
      out: String? = nil, files: [String]? = nil, all: Bool? = nil, interactive: Bool? = nil, find: String? = nil, code: String? = nil
    ) {
      (self.ref, self.text, self.key, self.selector, self.url, self.timeout) = (ref, text, key, selector, url, timeout)
      (self.out, self.files, self.all, self.interactive, self.find, self.code) = (out, files, all, interactive, find, code)
    }
  }

  public struct Reply: Codable, Sendable, Equatable {
    /// 给 Agent 读的全文；失败时是那句报错。
    public var text: String
    public var failed: Bool
    /// `--json` 时与 `text` 一起给出的字段（只有几个动词有）。
    public var info: Info?

    public static func done(_ text: String, _ info: Info? = nil) -> Reply { Reply(text: text, failed: false, info: info) }
    public static func refused(_ text: String) -> Reply { Reply(text: text, failed: true, info: nil) }
  }

  public struct Info: Codable, Sendable, Equatable {
    public var url: String?
    public var title: String?
    public var path: String?
    public var width: Int?
    public var height: Int?
    public var bytes: Int?

    public init(url: String? = nil, title: String? = nil, path: String? = nil, width: Int? = nil, height: Int? = nil, bytes: Int? = nil) {
      (self.url, self.title, self.path, self.width, self.height, self.bytes) = (url, title, path, width, height, bytes)
    }
  }

  public enum Failure: Error, Equatable {
    /// 没人在听这个套接字（文件不在、或留下的是崩溃前的）。
    case notListening
    /// `timeout` 内没读到应答。
    case timedOut
    case broken(String)
  }

  /// 发一条请求、读回应答；`timeout` 内没读完是 `timedOut`，连接随之关掉，App 那边在做的那一件跟着取消。
  public static func ask(_ request: Request, path: String, timeout: Duration) throws(Failure) -> Reply {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .broken("socket: \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    var address = try address(path)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { throw .notListening }
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

  /// 在 `path` 上听，直到对象释放。每条请求先过 `admit`（会话只操作自己的预览），过了才交给 `handle`；被拒的不进 `handle`。
  /// `handle` 在对方断开时被取消（任务取消），要在挂起点上看取消。
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
      // 先改权限再 listen：listen 之前谁也连不上，改权限之前那一刻没有空子
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

  /// 会话只操作自己的预览：会话号是 Agent 给命令带的环境变量（同 `show`）；这个会话有在跑的 Agent 进程时，连进来的必须是它的后代。
  /// 终端里自开、没记着进程的会话只能按会话号放行。
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

  /// 一行请求：客户端连上就写，5 秒没写完的不等。
  @concurrent private static func readRequest(_ fd: Int32) async -> Read {
    limit(fd, SO_RCVTIMEO, .seconds(5))
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while !data.contains(UInt8(ascii: "\n")) {
      let got = read(fd, &buffer, buffer.count)
      guard got > 0 else { return .failure("请求没读完") }
      data.append(buffer, count: got)
      guard data.count < 4_000_000 else { return .failure("请求太大") }
    }
    let line = data.prefix { $0 != UInt8(ascii: "\n") }
    guard let request = try? JSONDecoder().decode(Request.self, from: line) else { return .failure("请求读不懂：命令行与 App 不是同一版") }
    return .success(request)
  }

  /// 请求之后对方不再写：一有可读就是断开了。
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
