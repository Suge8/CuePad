#if os(macOS)
import Darwin
import Foundation

/// 本机正在监听、属于会话、答得出网页的开发服务（活预览自己认出的地址、会话条上哪些会话有活预览；`cuepad live` 不给地址时也用它）。
/// 属于哪个会话按这个顺序认，前两条认到就只归它：
/// 1. 进程的环境里带着会话 id（`AgentKind.sessionVariables`，Agent 给每条命令带的那个，`cuepad show` 认会话也是它）：谁起的就是谁的。
///    Agent 常用 nohup 把服务甩到后台，进程树断了、工作目录在别处都还认得；带着的是别的会话的 id（这一轮没问到的、已结束的）就谁也不归。
/// 2. 是会话 Agent 进程的后代：系统自带的可执行文件（/usr/bin/ruby）内核不给读环境，靠这条。
/// 3. 都没有的（你自己在终端里起的）看工作目录：在会话的工作目录之内，目录包着它的几个会话都算；会话目录是主目录、根目录这类过宽的不算。
///    只按目录认时，同一个项目里开着的几个会话会一起认领 Agent 甩到后台的服务（实测：三个会话都亮了预览、点进去是同一页）。
/// 进程表只经 libproc 与 sysctl（同一用户的进程都读得到，别的用户的读不到也用不着），不起 lsof；一次扫多少个会话都只读一遍进程表。
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

  /// 键是会话 id；认不出服务的会话不在里面。每个会话的地址最近起来的在前。
  public mutating func find(for owners: [String: Owner]) async -> [String: [URL]] {
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
    var found: [String: [URL]] = [:]
    for (listener, keys) in listeners where pages[listener]?.page == true {
      for key in keys where found[key]?.contains(listener.url) != true { found[key, default: []].append(listener.url) }
    }
    return found
  }

  /// 这几个会话名下在监听的端口，答不答网页都算（活预览的隧道放行它们：页面要调的只回 JSON 的接口也在里面）。
  public static func ports(for owners: [String: Owner]) async -> [String: Set<Int>] {
    var ports: [String: Set<Int>] = [:]
    for (listener, keys) in await listening(for: owners) {
      guard let port = listener.url.port else { continue }
      for key in keys { ports[key, default: []].insert(port) }
    }
    return ports
  }

  /// 最近起来的在前。
  @concurrent static func listening(for owners: [String: Owner]) async -> [(listener: Listener, owners: Set<String>)] {
    guard !owners.isEmpty else { return [] }
    let me = getpid()
    let info = Dictionary(processes().compactMap { pid in bsd(pid).map { (pid, $0) } }, uniquingKeysWith: { first, _ in first })
    // 同一端口号上别人的监听口也要看：谁接哪个地址由它们一起定（`reach`）
    let listening: [Socket] = info.keys.flatMap { sockets($0) }
    let candidates = Set(listening.map(\.pid)).subtracting([me])
    // 空的是带着别的会话的 id：后两条不再认它
    var mine: [pid_t: Set<String>] = [:]
    for (pid, session) in sessions(of: candidates) { mine[pid] = owners[session] == nil ? [] : [session] }
    var children: [pid_t: [pid_t]] = [:]
    for (pid, item) in info { children[pid_t(item.pbi_ppid), default: []].append(pid) }
    var descended: [pid_t: Set<String>] = [:]
    for (key, owner) in owners {
      guard let process = owner.process, let root = info[process.pid], started(root) == process.startedAt else { continue }
      var queue = children[process.pid] ?? []
      while let pid = queue.popLast() {
        guard descended[pid]?.contains(key) != true else { continue }
        descended[pid, default: []].insert(key)
        queue += children[pid] ?? []
      }
    }
    var directories: [String: Set<String>] = [:]
    for (key, owner) in owners {
      if let directory = owner.directory.flatMap(realPath), !tooWide(directory) { directories[directory, default: []].insert(key) }
    }
    for pid in candidates where mine[pid] == nil {
      if let keys = descended[pid] {
        mine[pid] = keys
        continue
      }
      // 顺着工作目录往上查表，不拿每个进程去比每个会话
      guard !directories.isEmpty, var path = workingDirectory(pid) else { continue }
      var keys = Set<String>()
      while true {
        keys.formUnion(directories[path] ?? [])
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { break }
        path = String(path[..<slash])
      }
      mine[pid] = keys
    }
    var found: [(listener: Listener, owners: Set<String>)] = []
    for socket in listening {
      guard let keys = mine[socket.pid], !keys.isEmpty, let url = reach(socket, among: listening) else { continue }
      found.append((Listener(pid: socket.pid, started: started(info[socket.pid]!), url: url), keys))
    }
    return found.sorted { ($0.listener.started, -($0.listener.url.port ?? 0)) > ($1.listener.started, -($1.listener.url.port ?? 0)) }
  }

  /// 这几个进程起来时的环境里带着的会话 id（`AgentKind.sessionVariables` 里第一个有值的，同 `cuepad show`）；没带、读不到的不在里面。
  /// 内核只给读同一用户、不是系统自带可执行文件的进程（实测 node、bun、python 读得到，/usr/bin/ruby、/bin/sleep 读不到）。
  static func sessions(of pids: Set<pid_t>) -> [pid_t: String] {
    var limit = 0, limitSize = MemoryLayout<Int>.size
    guard sysctlbyname("kern.argmax", &limit, &limitSize, nil, 0) == 0, limit > 0 else { return [:] }
    var buffer = [UInt8](repeating: 0, count: limit)
    let wanted = AgentKind.sessionVariables.map { Array("\($0)=".utf8) }
    var sessions: [pid_t: String] = [:]
    for pid in pids {
      var mib = [CTL_KERN, KERN_PROCARGS2, pid]
      var size = limit
      guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { continue }
      // 排法：参数个数，可执行文件路径，补的零，那几个参数，然后是环境；每段以零结尾
      var skip = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
      var at = MemoryLayout<Int32>.size
      while at < size, buffer[at] != 0 { at += 1 }
      while at < size, buffer[at] == 0 { at += 1 }
      var values = [String?](repeating: nil, count: wanted.count)
      while at < size {
        let end = buffer[at..<size].firstIndex(of: 0) ?? size
        if skip > 0 { skip -= 1 } else if end == at { break } else {
          for (index, name) in wanted.enumerated() where end - at > name.count && buffer[at..<at + name.count].elementsEqual(name) {
            values[index] = String(decoding: buffer[(at + name.count)..<end], as: UTF8.self)
          }
        }
        at = end + 1
      }
      if let session = values.lazy.compactMap(\.self).first { sessions[pid] = session }
    }
    return sessions
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

  /// `pid` 是不是 `ancestor` 的后代（顺着父进程往上找；中途有进程退了、被 launchd 收养的不算）。
  static func descends(_ pid: pid_t, from ancestor: SessionProcess) -> Bool {
    guard ancestor.isRunning else { return false }
    var current = pid
    while current > 1, let info = bsd(current) {
      let parent = pid_t(info.pbi_ppid)
      if parent == ancestor.pid { return true }
      current = parent
    }
    return false
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
#endif
