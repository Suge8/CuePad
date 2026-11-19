#if os(macOS)
import Darwin
import Foundation

/// 本机正在监听、属于一个会话、答得出网页的开发服务（活预览自己认出的地址；`cuepad live` 不给地址时也用它）。
/// 属于会话：是会话 Agent 进程的后代，或工作目录在会话的工作目录之内——Agent 常用 nohup 把服务甩到后台，进程树断了靠目录兜住；
/// 终端里自开、没有进程号的会话只能靠目录。会话目录是主目录、根目录这类过宽的，目录那条不算。
/// 进程表只经 libproc（同一用户的进程都读得到，别的用户的读不到也用不着），不起 lsof；一次扫约 2–3 ms。
public struct LiveServers: Sendable {
  public struct Owner: Equatable, Sendable {
    public var process: SessionProcess?
    public var directory: String?

    public init(process: SessionProcess?, directory: String?) {
      self.process = process
      self.directory = directory
    }
  }

  struct Listener: Hashable {
    let pid: pid_t
    let started: Int64
    /// 只绑在一个具体地址上的（局域网卡）就问那个地址：同一端口号可能另有别的进程绑在 127.0.0.1 上，问 localhost 答的是它。
    let url: URL
  }

  /// 问过的监听口答不答网页：答了的同一个进程的同一个口不再问；没答的过一会儿再问（服务先开口、页面后就绪）。
  private var pages: [Listener: (page: Bool, at: ContinuousClock.Instant)] = [:]
  private static let retry = Duration.seconds(5)

  public init() {}

  /// 最近起来的在前。
  public mutating func find(for owner: Owner) async -> [URL] {
    let listeners = await Self.listening(for: owner)
    let now = ContinuousClock.now
    for listener in listeners {
      if let known = pages[listener], known.page || now - known.at < Self.retry { continue }
      pages[listener] = (await Self.answersPage(listener.url), now)
    }
    pages = pages.filter { listeners.contains($0.key) }
    var seen = Set<URL>()
    return listeners.filter { pages[$0]?.page == true && seen.insert($0.url).inserted }.map(\.url)
  }

  public static func url(port: Int) -> URL { URL(string: "http://localhost:\(port)")! }

  @concurrent static func listening(for owner: Owner) async -> [Listener] {
    let me = getpid()
    let all = processes()
    let info = Dictionary(all.compactMap { pid in bsd(pid).map { (pid, $0) } }, uniquingKeysWith: { first, _ in first })
    var mine = Set<pid_t>()
    if let process = owner.process, let root = info[process.pid], started(root) == process.startedAt {
      var children: [pid_t: [pid_t]] = [:]
      for (pid, item) in info { children[pid_t(item.pbi_ppid), default: []].append(pid) }
      var queue = children[process.pid] ?? []
      while let pid = queue.popLast() {
        if mine.insert(pid).inserted { queue += children[pid] ?? [] }
      }
    }
    if let directory = owner.directory.flatMap(realPath), !tooWide(directory) {
      for pid in info.keys where !mine.contains(pid) {
        if let cwd = workingDirectory(pid), cwd == directory || cwd.hasPrefix(directory + "/") { mine.insert(pid) }
      }
    }
    mine.remove(me)
    return mine.flatMap { pid in ports(pid).map { Listener(pid: pid, started: started(info[pid]!), url: $0) } }
      .sorted { ($0.started, -($0.url.port ?? 0)) > ($1.started, -($1.url.port ?? 0)) }
  }

  /// 数据库、调试端口、语言服务筛掉：只留回 HTML 的。只等到响应头。
  @concurrent static func answersPage(_ url: URL) async -> Bool {
    var request = URLRequest(url: url)
    request.setValue("text/html", forHTTPHeaderField: "Accept")
    guard let (bytes, response) = try? await probe.bytes(for: request) else { return false }
    bytes.task.cancel()
    return response.mimeType == "text/html"
  }

  private static let probe: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 1
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  /// 根目录、主目录与它的上级（/Users）：底下什么进程都有。
  static func tooWide(_ directory: String) -> Bool {
    let home = realPath(UserHome.directory.path) ?? UserHome.directory.path
    return directory == "/" || home == directory || home.hasPrefix(directory + "/")
  }

  /// 内核报的工作目录是解开链接的（/private/tmp）：会话目录也解开再比。`URL.resolvingSymlinksInPath` 会反过来剥掉 /private，不用它。
  static func realPath(_ path: String) -> String? {
    guard !path.isEmpty, let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private static func processes() -> [pid_t] {
    var buffer = [pid_t](repeating: 0, count: 8192)
    let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
    return buffer.prefix(Int(max(0, bytes)) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
  }

  private static func bsd(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
  }

  /// 同 `SessionProcess.startedAt`：微秒。
  private static func started(_ info: proc_bsdinfo) -> Int64 { Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec) }

  private static func workingDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }

  /// 这个进程起来的时刻（`CueStore.liveAddresses` 之后的命令以 App 进程起来为界，不以订阅开始为界）。
  public static func launched(_ pid: pid_t = getpid()) -> Date? {
    bsd(pid).map { Date(timeIntervalSince1970: Double(started($0)) / 1_000_000) }
  }

  /// 监听的口，按绑的地址给出要问的网址：通配与回环写 localhost，具体地址照写。
  private static func ports(_ pid: pid_t) -> [URL] {
    var ports: [URL] = []
    for fd in fds(pid) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
      var socket = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size, socket.psi.soi_kind == SOCKINFO_TCP else { continue }
      let tcp = socket.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
      let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
      let url = URL(string: "http://\(host(tcp.tcpsi_ini)):\(port)")!
      if !ports.contains(url) { ports.append(url) }
    }
    return ports
  }

  private static func fds(_ pid: pid_t) -> ArraySlice<proc_fdinfo> {
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.size + 16)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
    return fds.prefix(Int(max(0, got)) / MemoryLayout<proc_fdinfo>.size)
  }

  /// 有没有 CuePad.app（可执行文件 `….app/Contents/MacOS/CuePad`；命令行在 Helpers 里、小组件在 PlugIns 里，都不算）开着这份库文件。
  static func appHolding(_ file: String) -> Bool {
    guard let file = realPath(file) else { return false }
    return processes().contains { pid in
      guard pid != getpid(), executable(pid)?.hasSuffix(".app/Contents/MacOS/CuePad") == true else { return false }
      return fds(pid).contains { fd in
        guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { return false }
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return false }
        return withUnsafeBytes(of: info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == file
      }
    }
  }

  private static func executable(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
  }

  private static func host(_ socket: in_sockinfo) -> String {
    var address = socket.insi_laddr
    if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
      let ip = address.ina_46.i46a_addr4
      if ip.s_addr == INADDR_ANY || UInt32(bigEndian: ip.s_addr) >> 24 == 127 { return "localhost" }
      var raw = ip
      return text(AF_INET, &raw, INET_ADDRSTRLEN)
    }
    let six = withUnsafeBytes(of: &address.ina_6) { Array($0) }
    if six.allSatisfy({ $0 == 0 }) || six == Array(repeating: 0, count: 15) + [1] { return "localhost" }
    return "[\(text(AF_INET6, &address.ina_6, INET6_ADDRSTRLEN))]"
  }

  private static func text(_ family: Int32, _ address: UnsafeRawPointer, _ size: Int32) -> String {
    var buffer = [CChar](repeating: 0, count: Int(size))
    _ = inet_ntop(family, address, &buffer, socklen_t(size))
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// 一个会话请用户看的本机网页（`cuepad live`）：只记在本机表 `liveAddresses`，不同步——地址是这台 Mac 上的服务。每个会话留最后一条。
public struct LiveAddress: Equatable, Sendable {
  public var sessionID: String
  public var url: URL
  /// 由 `LiveServers` 认出的（Agent 没给地址）：服务换了端口跟过去；Agent 明说的不跟。
  public var found: Bool
  public var sentAt: Date

  public init(sessionID: String, url: URL, found: Bool, sentAt: Date) {
    self.sessionID = sessionID
    self.url = url
    self.found = found
    self.sentAt = sentAt
  }

  /// 输入的地址：只写端口（5173）当作本机；不写协议时本机、局域网与不带点的主机名用 http，其余用 https。
  public static func url(from text: String) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let port = Int(text) { return (1...65_535).contains(port) ? LiveServers.url(port: port) : nil }
    let full: String
    if text.contains("://") {
      full = text
    } else {
      let host = text.prefix { !":/?#".contains($0) }
      let local = !host.contains(".") || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
      full = (local ? "http://" : "https://") + text
    }
    guard let url = URL(string: full), url.host?.isEmpty == false, ["http", "https"].contains(url.scheme?.lowercased()),
      url.port.map({ (1...65_535).contains($0) }) ?? true
    else { return nil }
    return url
  }

  /// 给人看的：不写 http://、https://，路径只有 "/" 时也不写。
  public static func shown(_ url: URL) -> String {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url.absoluteString }
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.path == "/" ? "" : components.path
    return host + port + path + (components.query.map { "?\($0)" } ?? "")
  }
}

extension CueStore {
  /// 本机有没有开着这份资料库的 CuePad.app（`cuepad live` 交接前问）：看进程开着的文件，调试实例与正式版各开各的库，不会认错。
  /// 不用在线记录（`MacPresence`）：App 崩溃后它要到期限（10 分钟）才过期，这期间会说成开着。
  public nonisolated var appIsOpen: Bool { LiveServers.appHolding(databasePath) }

  /// 记下一条，顺手清掉一天前的（过了这么久的地址多半已经不在了）。
  public func sendLive(_ url: URL, to sessionID: String, found: Bool) throws {
    try write {
      let now = Date.stamp
      try db.run("DELETE FROM liveAddresses WHERE sentAt < ?", [now.addingTimeInterval(-86_400)])
      try db.run("INSERT OR REPLACE INTO liveAddresses (sessionID, url, found, sentAt) VALUES (?, ?, ?, ?)", [sessionID, url.absoluteString, found ? 1 : 0, now])
    }
  }

  public func liveAddresses() throws -> [LiveAddress] {
    try db.query("SELECT sessionID, url, found, sentAt FROM liveAddresses ORDER BY sessionID") { row in
      URL(string: row.text(1)).map { LiveAddress(sessionID: row.text(0), url: $0, found: row.int(2) == 1, sentAt: row.date(3)) }
    }.compactMap(\.self)
  }

  /// 认会话的服务要的：承载它的进程（本机表 `piProcesses`）与它的工作目录（会话索引）。
  public func liveOwner(_ sessionID: String) throws -> LiveServers.Owner {
    let process = try db.first("SELECT pid, startedAt FROM piProcesses WHERE sessionID = ?", [sessionID]) {
      SessionProcess(pid: Int32($0.int(0)), startedAt: $0.int(1))
    }
    return LiveServers.Owner(process: process, directory: try indexedSession(sessionID)?.cwd)
  }
}
#endif
