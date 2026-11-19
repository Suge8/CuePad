#if os(macOS)
import Darwin
import Foundation

/// 本机正在监听、属于会话、答得出网页的开发服务（活预览自己认出的地址、会话条上哪些会话有活预览；`cuepad live` 不给地址时也用它）。
/// 属于会话：是会话 Agent 进程的后代，或工作目录在会话的工作目录之内——Agent 常用 nohup 把服务甩到后台，进程树断了靠目录兜住；
/// 终端里自开、没有进程号的会话只能靠目录。会话目录是主目录、根目录这类过宽的，目录那条不算。
/// 一个进程是某个会话 Agent 的后代就只归它；按目录归的，目录包着它的几个会话都算。
/// 进程表只经 libproc（同一用户的进程都读得到，别的用户的读不到也用不着），不起 lsof；一次扫多少个会话都只读一遍进程表。
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
    /// 问得到这个进程的那个地址（`reach`）。
    let url: URL
  }

  /// 问过的监听口答不答网页：答了的同一个进程的同一个口不再问；没答的过一会儿再问（服务先开口、页面后就绪）。
  private var pages: [Listener: (page: Bool, at: ContinuousClock.Instant)] = [:]
  private static let retry = Duration.seconds(5)

  public init() {}

  /// 键是会话（`Owner` 的键）；认不出服务的会话不在里面。每个会话的地址最近起来的在前。
  public mutating func find<Key: Hashable & Sendable>(for owners: [Key: Owner]) async -> [Key: [URL]] {
    let listeners = await Self.listening(for: owners)
    let now = ContinuousClock.now
    // 一起问：接了连接却迟迟不答的口要等满超时，挨个问会把别的会话这一轮都拖住
    let asking = listeners.map(\.listener).filter { listener in pages[listener].map { !$0.page && now - $0.at >= Self.retry } ?? true }
    await withTaskGroup(of: (Listener, Bool).self) { group in
      for listener in asking { group.addTask { (listener, await Self.answersPage(listener.url)) } }
      for await (listener, page) in group { pages[listener] = (page, now) }
    }
    let all = Set(listeners.map(\.listener))
    pages = pages.filter { all.contains($0.key) }
    var found: [Key: [URL]] = [:]
    for (listener, keys) in listeners where pages[listener]?.page == true {
      for key in keys where found[key]?.contains(listener.url) != true { found[key, default: []].append(listener.url) }
    }
    return found
  }

  public static func url(port: Int) -> URL { URL(string: "http://localhost:\(port)")! }

  /// 最近起来的在前。
  @concurrent static func listening<Key: Hashable & Sendable>(for owners: [Key: Owner]) async -> [(listener: Listener, owners: Set<Key>)] {
    guard !owners.isEmpty else { return [] }
    let me = getpid()
    let info = Dictionary(processes().compactMap { pid in bsd(pid).map { (pid, $0) } }, uniquingKeysWith: { first, _ in first })
    var children: [pid_t: [pid_t]] = [:]
    for (pid, item) in info { children[pid_t(item.pbi_ppid), default: []].append(pid) }
    var mine: [pid_t: Set<Key>] = [:]
    for (key, owner) in owners {
      guard let process = owner.process, let root = info[process.pid], started(root) == process.startedAt else { continue }
      var queue = children[process.pid] ?? []
      while let pid = queue.popLast() {
        guard mine[pid]?.contains(key) != true else { continue }
        mine[pid, default: []].insert(key)
        queue += children[pid] ?? []
      }
    }
    var directories: [String: Set<Key>] = [:]
    for (key, owner) in owners {
      if let directory = owner.directory.flatMap(realPath), !tooWide(directory) { directories[directory, default: []].insert(key) }
    }
    if !directories.isEmpty {
      // 顺着工作目录往上查表，不拿每个进程去比每个会话：一千多个进程乘几十个会话的前缀比较要好几毫秒
      for pid in info.keys where mine[pid] == nil {
        guard var path = workingDirectory(pid) else { continue }
        var keys = Set<Key>()
        while true {
          keys.formUnion(directories[path] ?? [])
          guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { break }
          path = String(path[..<slash])
        }
        if !keys.isEmpty { mine[pid] = keys }
      }
    }
    mine[me] = nil
    guard !mine.isEmpty else { return [] }
    // 同一端口号上别人的监听口也要看：谁接哪个地址由它们一起定（`reach`）
    let listening: [Socket] = info.keys.flatMap { sockets($0) }
    var found: [(listener: Listener, owners: Set<Key>)] = []
    for socket in listening {
      guard let keys = mine[socket.pid], let url = reach(socket, among: listening) else { continue }
      found.append((Listener(pid: socket.pid, started: started(info[socket.pid]!), url: url), keys))
    }
    return found.sorted { ($0.listener.started, -($0.listener.url.port ?? 0)) > ($1.listener.started, -($1.listener.url.port ?? 0)) }
  }

  /// 一个在监听的 TCP 口：绑的地址（nil 是通配）与它接哪几族（v6 的通配不设 V6ONLY 时两族都接）。
  struct Socket {
    let pid: pid_t
    let port: Int
    let v4: Bool
    let v6: Bool
    let address: Address?
  }

  enum Address: Hashable {
    case v4(in_addr_t)
    case v6([UInt8])

    static let loopback4 = Address.v4(in_addr_t(0x7f00_0001).bigEndian)
    static let loopback6 = Address.v6(Array(repeating: 0, count: 15) + [1])

    var isLoopback: Bool {
      switch self {
      case .v4(let raw): UInt32(bigEndian: raw) >> 24 == 127
      case .v6: self == Self.loopback6
      }
    }

    var host: String {
      switch self {
      case .v4(var raw): text(AF_INET, &raw, INET_ADDRSTRLEN)
      case .v6(var bytes): "[\(text(AF_INET6, &bytes, INET6_ADDRSTRLEN))]"
      }
    }

    private func text(_ family: Int32, _ address: UnsafeRawPointer, _ size: Int32) -> String {
      var buffer = [CChar](repeating: 0, count: Int(size))
      _ = inet_ntop(family, address, &buffer, socklen_t(size))
      return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
  }

  /// 问哪个地址到得了这个口：连一个本机地址时，绑了这个具体地址的口先接，没有才轮到通配的。
  /// 问 localhost 时 127.0.0.1 与 ::1 都可能连上，只有两处都没有别人接时才问它；否则改问这个口自己接得到的那一个回环地址，都被别人接走就不认。
  /// 绑在局域网地址上的照问那个地址。
  static func reach(_ socket: Socket, among all: [Socket]) -> URL? {
    func url(_ host: String) -> URL? { URL(string: "http://\(host):\(socket.port)") }
    if let address = socket.address, !address.isLoopback { return url(address.host) }
    func answering(_ address: Address) -> Set<pid_t> {
      let here = all.filter { $0.port == socket.port }
      let exact = here.filter { $0.address == address }
      let wide = here.filter { $0.address == nil && (address == .loopback4 ? $0.v4 : $0.v6) }
      return Set((exact.isEmpty ? wide : exact).map(\.pid))
    }
    var own: [Address] = []
    if let address = socket.address { own = [address] } else {
      if socket.v4 { own.append(.loopback4) }
      if socket.v6 { own.append(.loopback6) }
    }
    let mine = own.filter { answering($0).contains(socket.pid) }
    guard let first = mine.first else { return nil }
    let shared = [Address.loopback4, .loopback6].allSatisfy { answering($0).subtracting([socket.pid]).isEmpty }
    return url(shared ? "localhost" : first.host)
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

  private static func sockets(_ pid: pid_t) -> [Socket] {
    fds(pid).compactMap { fd in
      guard fd.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_kind == SOCKINFO_TCP else { return nil }
      let tcp = info.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { return nil }
      let socket = tcp.tcpsi_ini
      let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport)))
      let v4 = socket.insi_vflag & UInt8(INI_IPV4) != 0, v6 = socket.insi_vflag & UInt8(INI_IPV6) != 0
      var local = socket.insi_laddr
      let address: Address?
      if v6 {
        let bytes = withUnsafeBytes(of: &local.ina_6) { Array($0) }
        address = bytes.allSatisfy { $0 == 0 } ? nil : .v6(bytes)
      } else {
        let raw = local.ina_46.i46a_addr4.s_addr
        address = raw == INADDR_ANY ? nil : .v4(raw)
      }
      return Socket(pid: pid, port: port, v4: v4, v6: v6, address: address)
    }
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

  /// 这几台（本机）上没结束的会话，各自的进程与工作目录，键是会话 id：已结束的不认服务。
  public func liveOwners(hosts: [String]) throws -> [String: LiveServers.Owner] {
    guard !hosts.isEmpty else { return [:] }
    let marks = Array(repeating: "?", count: hosts.count).joined(separator: ", ")
    let rows = try db.query(
      """
      SELECT s.sessionID, p.pid, p.startedAt, i.cwd FROM piSessionStates s
      LEFT JOIN piProcesses p ON p.sessionID = s.sessionID LEFT JOIN piSessions i ON i.id = s.sessionID
      WHERE s.hostID IN (\(marks)) AND \(WorkState.outsideSQL(WorkState.closed, column: "s.state"))
      """, hosts
    ) { row in
      (row.text(0), LiveServers.Owner(
        process: row.intOrNil(1).map { SessionProcess(pid: Int32($0), startedAt: row.int(2)) }, directory: row.textOrNil(3)))
    }
    return Dictionary(rows, uniquingKeysWith: { first, _ in first })
  }
}
#endif
